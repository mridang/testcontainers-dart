@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:testcontainers/src/docker_client.dart';

/// Encodes [text] as UTF-8 bytes.
Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Builds a single HTTP chunked body frame:
/// `<hex-size>\r\n<data>\r\n`.
Uint8List _chunk(String data) {
  final dataBytes = utf8.encode(data);
  final header = '${dataBytes.length.toRadixString(16)}\r\n';
  return Uint8List.fromList([
    ...utf8.encode(header),
    ...dataBytes,
    ...[13, 10], // CRLF after chunk
  ]);
}

/// Builds the terminating `0\r\n` chunk.
Uint8List _termChunk() => _bytes('0\r\n');

/// Builds a Docker multiplexed log frame.
///
/// Header: 1 byte stream-type, 3 bytes padding (0), 4 bytes big-endian size.
Uint8List _logFrame(int streamType, String payload) {
  final payloadBytes = utf8.encode(payload);
  final size = payloadBytes.length;
  return Uint8List.fromList([
    streamType, 0, 0, 0, // type + padding
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...payloadBytes,
  ]);
}

void main() {
  late DockerClient client;

  setUp(() {
    client = DockerClient.testOnly();
  });

  // ---------------------------------------------------------------------------
  // _decodeChunked
  // ---------------------------------------------------------------------------
  group('DockerClient.decodeChunked', () {
    test('decodes a single chunk', () {
      final input = Uint8List.fromList([..._chunk('hello'), ..._termChunk()]);
      final result = client.decodeChunked(input);
      expect(utf8.decode(result), equals('hello'));
    });

    test('decodes multiple chunks', () {
      final input = Uint8List.fromList([
        ..._chunk('foo'),
        ..._chunk('bar'),
        ..._chunk('baz'),
        ..._termChunk(),
      ]);
      final result = client.decodeChunked(input);
      expect(utf8.decode(result), equals('foobarbaz'));
    });

    test('returns empty bytes for only a terminating chunk', () {
      final input = _termChunk();
      expect(client.decodeChunked(input), isEmpty);
    });

    test('returns empty bytes for empty input', () {
      expect(client.decodeChunked(Uint8List(0)), isEmpty);
    });

    test('stops at truncated chunk without crashing', () {
      // A chunk that claims 100 bytes but only 3 are present.
      final truncated = Uint8List.fromList([
        ..._bytes('64\r\n'), // hex 64 = 100 bytes
        ...[1, 2, 3], // only 3 bytes of the promised 100
      ]);
      // Must not throw — just returns whatever it decoded so far.
      expect(() => client.decodeChunked(truncated), returnsNormally);
    });

    test('handles chunk with no CRLF (malformed) gracefully', () {
      // No CRLF at all — _findCrlf returns -1 and decoding aborts cleanly.
      final malformed = _bytes('5hello');
      expect(() => client.decodeChunked(malformed), returnsNormally);
      expect(client.decodeChunked(malformed), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // _stripDockerLogHeaders
  // ---------------------------------------------------------------------------
  group('DockerClient.stripDockerLogHeaders', () {
    test('strips a single stdout frame (stream type 1)', () {
      final frame = _logFrame(1, 'hello stdout');
      final result = client.stripDockerLogHeaders(frame);
      expect(utf8.decode(result), equals('hello stdout'));
    });

    test('strips a single stderr frame (stream type 2)', () {
      final frame = _logFrame(2, 'hello stderr');
      final result = client.stripDockerLogHeaders(frame);
      expect(utf8.decode(result), equals('hello stderr'));
    });

    test('concatenates payloads from multiple frames', () {
      final frames = Uint8List.fromList([
        ..._logFrame(1, 'line 1\n'),
        ..._logFrame(1, 'line 2\n'),
      ]);
      final result = client.stripDockerLogHeaders(frames);
      expect(utf8.decode(result), equals('line 1\nline 2\n'));
    });

    test('returns original bytes when data has no valid frames (TTY mode)', () {
      // Plain text with no 8-byte header — returns data unchanged.
      final plain = _bytes('plain log line');
      final result = client.stripDockerLogHeaders(plain);
      expect(result, equals(plain));
    });

    test('returns empty for empty input', () {
      final result = client.stripDockerLogHeaders(Uint8List(0));
      expect(result, isEmpty);
    });

    test('handles truncated frame header gracefully', () {
      // Only 6 bytes — not enough for a full 8-byte header.
      final truncated = Uint8List.fromList([1, 0, 0, 0, 0, 5]);
      expect(
        () => client.stripDockerLogHeaders(truncated),
        returnsNormally,
      );
    });

    test('concatenates mixed stdout and stderr frames in order', () {
      // Stream types 1 (stdout) and 2 (stderr) are treated identically —
      // both get their payloads appended in sequence.
      final frames = Uint8List.fromList([
        ..._logFrame(1, 'out'),
        ..._logFrame(2, 'err'),
        ..._logFrame(1, 'out2'),
      ]);
      final result = client.stripDockerLogHeaders(frames);
      expect(utf8.decode(result), equals('outerrout2'));
    });

    test('strips frame with zero-byte payload', () {
      // An 8-byte header with payload length = 0 is valid — no payload follows.
      final header = Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0]);
      final nonEmpty = _logFrame(1, 'data');
      final frames = Uint8List.fromList([...header, ...nonEmpty]);
      final result = client.stripDockerLogHeaders(frames);
      // The zero-byte frame contributes nothing; only 'data' is in the output.
      expect(utf8.decode(result), equals('data'));
    });

    test('handles a frame whose stream-type byte is 0 (stdin)', () {
      // Docker does not normally emit stdin frames in log output but the
      // parser must not crash — stream type 0 is treated the same as any
      // other type: its payload is concatenated.
      final frame = _logFrame(0, 'stdin_data');
      final result = client.stripDockerLogHeaders(frame);
      expect(utf8.decode(result), equals('stdin_data'));
    });
  });

  // ---------------------------------------------------------------------------
  // _parseHttpResponse
  // ---------------------------------------------------------------------------
  group('DockerClient.parseHttpResponse', () {
    /// Builds a minimal HTTP/1.0 response byte buffer.
    ///
    /// Each line in the header section is terminated with `\r\n` as required by
    /// HTTP/1.0. The header section is followed by a blank `\r\n` line, then
    /// the UTF-8-encoded [body].
    Uint8List buildResponse({
      String statusLine = 'HTTP/1.0 200 OK',
      Map<String, String> headers = const {},
      String body = '',
    }) {
      final sb = StringBuffer()..write('$statusLine\r\n');
      for (final entry in headers.entries) {
        sb.write('${entry.key}: ${entry.value}\r\n');
      }
      sb.write('\r\n'); // blank line separating headers from body
      return Uint8List.fromList([
        ...utf8.encode(sb.toString()),
        ...utf8.encode(body),
      ]);
    }

    test('parses a 200 OK response', () {
      final bytes = buildResponse(body: '{"Id":"abc"}');
      final result = client.parseHttpResponse(bytes);
      expect(result.statusCode, equals(200));
      expect(utf8.decode(result.body), equals('{"Id":"abc"}'));
    });

    test('parses a 201 Created response', () {
      final bytes =
          buildResponse(statusLine: 'HTTP/1.0 201 Created', body: '{}');
      final result = client.parseHttpResponse(bytes);
      expect(result.statusCode, equals(201));
    });

    test('parses a 204 No Content response (empty body)', () {
      final bytes = buildResponse(statusLine: 'HTTP/1.0 204 No Content');
      final result = client.parseHttpResponse(bytes);
      expect(result.statusCode, equals(204));
      expect(result.body, isEmpty);
    });

    test('parses a 404 Not Found response', () {
      final bytes = buildResponse(
        statusLine: 'HTTP/1.0 404 Not Found',
        body: 'no such container',
      );
      final result = client.parseHttpResponse(bytes);
      expect(result.statusCode, equals(404));
    });

    test('parses a 500 Internal Server Error response', () {
      final bytes = buildResponse(
        statusLine: 'HTTP/1.0 500 Internal Server Error',
        body: 'server error',
      );
      final result = client.parseHttpResponse(bytes);
      expect(result.statusCode, equals(500));
    });

    test('headers are lowercased', () {
      final bytes = buildResponse(
        headers: {'Content-Type': 'application/json'},
        body: '{}',
      );
      final result = client.parseHttpResponse(bytes);
      expect(result.headers.containsKey('content-type'), isTrue);
      expect(result.headers['content-type'], equals('application/json'));
      // Original-case key must not be present.
      expect(result.headers.containsKey('Content-Type'), isFalse);
    });

    test('multiple headers are all parsed', () {
      final bytes = buildResponse(
        headers: {
          'Content-Type': 'application/json',
          'Docker-Experimental': 'true',
          'Server': 'Docker/24.0.0',
        },
        body: '{}',
      );
      final result = client.parseHttpResponse(bytes);
      expect(result.headers['content-type'], equals('application/json'));
      expect(result.headers['docker-experimental'], equals('true'));
      expect(result.headers['server'], equals('Docker/24.0.0'));
    });

    test(
        'malformed response (no CRLF-CRLF) returns status 500 and body is '
        'the raw bytes', () {
      // No blank line separating headers from body → header parser fails.
      final malformed = _bytes('HTTP/1.0 200 OK\r\nsome garbage');
      final result = client.parseHttpResponse(malformed);
      expect(result.statusCode, equals(500));
      // Original bytes are returned unchanged.
      expect(result.body, equals(malformed));
    });

    test('empty byte buffer returns status 500 and empty body', () {
      final result = client.parseHttpResponse(Uint8List(0));
      expect(result.statusCode, equals(500));
    });

    test('chunked body is decoded transparently', () {
      // Build the header section manually and append chunked body.
      final headerStr = 'HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n';
      final headerBytes = utf8.encode(headerStr);
      final chunkedBody = Uint8List.fromList([
        ..._chunk('hello'),
        ..._termChunk(),
      ]);
      final raw = Uint8List.fromList([...headerBytes, ...chunkedBody]);
      final result = client.parseHttpResponse(raw);
      expect(result.statusCode, equals(200));
      expect(utf8.decode(result.body), equals('hello'));
    });

    test('non-chunked body is returned as-is', () {
      final bytes = buildResponse(
        headers: {'Content-Length': '5'},
        body: 'hello',
      );
      final result = client.parseHttpResponse(bytes);
      expect(utf8.decode(result.body), equals('hello'));
    });

    test('header value with colon is not split at the colon', () {
      // E.g. "Location: http://host:port/path" should preserve the full value.
      final bytes = buildResponse(
        headers: {'Location': 'http://localhost:2375/v1.41/containers'},
      );
      final result = client.parseHttpResponse(bytes);
      expect(
        result.headers['location'],
        equals('http://localhost:2375/v1.41/containers'),
      );
    });

    test('body containing null bytes survives round-trip', () {
      // The Docker API may return binary data (e.g. tar archives).
      // Build response manually because buildResponse() uses utf8.encode for body.
      const headerStr = 'HTTP/1.0 200 OK\r\n\r\n';
      final payload = Uint8List.fromList([0, 1, 2, 255, 128]);
      final raw = Uint8List.fromList([...utf8.encode(headerStr), ...payload]);
      final result = client.parseHttpResponse(raw);
      expect(result.statusCode, equals(200));
      expect(result.body, equals(payload));
    });
  });

  // ---------------------------------------------------------------------------
  // Additional decodeChunked tests
  // ---------------------------------------------------------------------------
  group('DockerClient.decodeChunked — additional edge cases', () {
    test('chunk whose size is exactly 1 byte is decoded correctly', () {
      final data = Uint8List.fromList([..._chunk('x'), ..._termChunk()]);
      expect(utf8.decode(client.decodeChunked(data)), equals('x'));
    });

    test('two consecutive single-byte chunks', () {
      final data = Uint8List.fromList([
        ..._chunk('a'),
        ..._chunk('b'),
        ..._termChunk(),
      ]);
      expect(utf8.decode(client.decodeChunked(data)), equals('ab'));
    });

    test('chunk with binary payload (non-ASCII bytes)', () {
      // Binary data (e.g. a Docker archive) must survive round-trip.
      final payload = Uint8List.fromList([0x00, 0xFF, 0x7F, 0x80]);
      final sizeHex = payload.length.toRadixString(16);
      final data = Uint8List.fromList([
        ...utf8.encode('$sizeHex\r\n'),
        ...payload,
        ...[13, 10], // CRLF
        ..._termChunk(),
      ]);
      final decoded = client.decodeChunked(data);
      expect(decoded, equals(payload));
    });
  });
}
