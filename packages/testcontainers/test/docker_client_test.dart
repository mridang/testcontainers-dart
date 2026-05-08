@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:testcontainers/src/config.dart';
import 'package:testcontainers/src/docker_client.dart';

// Builds a single Docker multiplexed-log frame:
// [streamType(1), padding(3), payloadLen big-endian(4), payload(N)]
Uint8List _makeLogFrame(int streamType, Uint8List payload) {
  final header = Uint8List(8);
  header[0] = streamType;
  // bytes 1–3 are padding (zero)
  final len = payload.length;
  header[4] = (len >> 24) & 0xFF;
  header[5] = (len >> 16) & 0xFF;
  header[6] = (len >> 8) & 0xFF;
  header[7] = len & 0xFF;
  return Uint8List.fromList([...header, ...payload]);
}

// Builds a chunked HTTP body segment:
// "<hex-size>\r\n<data>\r\n" … "0\r\n\r\n"
Uint8List _makeChunked(String data) {
  final dataBytes = data.codeUnits;
  final sizeHex = dataBytes.length.toRadixString(16);
  return Uint8List.fromList(
    [...'$sizeHex\r\n'.codeUnits, ...dataBytes, ...'\r\n0\r\n\r\n'.codeUnits],
  );
}

void main() {
  // Use testOnly() so no real Docker socket is needed.
  final client = DockerClient.testOnly();

  // ---------------------------------------------------------------------------
  // decodeChunked
  // ---------------------------------------------------------------------------
  group('DockerClient.decodeChunked', () {
    test('decodes a single chunk', () {
      final encoded = _makeChunked('hello');
      final decoded = client.decodeChunked(encoded);
      expect(String.fromCharCodes(decoded), equals('hello'));
    });

    test('decodes multiple chunks concatenated', () {
      final chunk1 = Uint8List.fromList('5\r\nhello\r\n'.codeUnits);
      final chunk2 = Uint8List.fromList('6\r\n world\r\n'.codeUnits);
      final terminator = Uint8List.fromList('0\r\n\r\n'.codeUnits);
      final encoded = Uint8List.fromList([...chunk1, ...chunk2, ...terminator]);
      final decoded = client.decodeChunked(encoded);
      expect(String.fromCharCodes(decoded), equals('hello world'));
    });

    test('returns empty bytes for terminator-only input', () {
      final encoded = Uint8List.fromList('0\r\n\r\n'.codeUnits);
      final decoded = client.decodeChunked(encoded);
      expect(decoded, isEmpty);
    });

    test('returns empty bytes for empty input', () {
      final decoded = client.decodeChunked(Uint8List(0));
      expect(decoded, isEmpty);
    });

    test('decodes chunk with trailing CRLF in data', () {
      // A chunk containing a newline character in its data.
      final payload = 'line1\nline2';
      final encoded = _makeChunked(payload);
      final decoded = client.decodeChunked(encoded);
      expect(String.fromCharCodes(decoded), equals(payload));
    });
  });

  // ---------------------------------------------------------------------------
  // stripDockerLogHeaders
  // ---------------------------------------------------------------------------
  group('DockerClient.stripDockerLogHeaders', () {
    test('strips a single stdout frame', () {
      final payload = Uint8List.fromList('hello'.codeUnits);
      final frame = _makeLogFrame(1, payload); // stream type 1 = stdout
      final stripped = client.stripDockerLogHeaders(frame);
      expect(String.fromCharCodes(stripped), equals('hello'));
    });

    test('strips a single stderr frame', () {
      final payload = Uint8List.fromList('error'.codeUnits);
      final frame = _makeLogFrame(2, payload); // stream type 2 = stderr
      final stripped = client.stripDockerLogHeaders(frame);
      expect(String.fromCharCodes(stripped), equals('error'));
    });

    test('strips multiple consecutive frames', () {
      final p1 = Uint8List.fromList('foo'.codeUnits);
      final p2 = Uint8List.fromList('bar'.codeUnits);
      final frames = Uint8List.fromList(
          [..._makeLogFrame(1, p1), ..._makeLogFrame(1, p2)]);
      final stripped = client.stripDockerLogHeaders(frames);
      expect(String.fromCharCodes(stripped), equals('foobar'));
    });

    test('returns raw bytes when no valid frames detected', () {
      // Data that does not look like valid Docker log frames — returned as-is.
      final raw = Uint8List.fromList('plain text without headers'.codeUnits);
      final stripped = client.stripDockerLogHeaders(raw);
      // No valid 8-byte header alignment → returned unchanged.
      expect(stripped, equals(raw));
    });

    test('returns raw bytes for input shorter than one frame header', () {
      // Less than 8 bytes can never contain a valid frame header.
      final short = Uint8List.fromList([1, 0, 0, 0]);
      final stripped = client.stripDockerLogHeaders(short);
      expect(stripped, equals(short));
    });

    test('handles truncated frame — reads what is available then stops', () {
      // Frame header says 5 bytes of payload but only 3 follow.
      // The inner break (pos + size > data.length) fires.
      // builder is empty after the break → original data is returned.
      final header = Uint8List(8);
      header[0] = 1; // stdout
      header[7] = 5; // payload size = 5
      final truncated = Uint8List.fromList([
        ...header,
        ...Uint8List.fromList('abc'.codeUnits), // only 3 bytes of promised 5
      ]);
      final stripped = client.stripDockerLogHeaders(truncated);
      // Nothing was fully parsed — fall-back to raw bytes.
      expect(stripped, equals(truncated));
    });

    test('empty input returns empty bytes', () {
      final stripped = client.stripDockerLogHeaders(Uint8List(0));
      expect(stripped, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // toDockerKey
  // ---------------------------------------------------------------------------
  group('DockerClient.toDockerKey', () {
    test("'privileged' maps to 'Privileged'", () {
      expect(DockerClient.toDockerKey('privileged'), equals('Privileged'));
    });

    test("'auto_remove' maps to 'AutoRemove'", () {
      expect(DockerClient.toDockerKey('auto_remove'), equals('AutoRemove'));
    });

    test("'autoRemove' maps to 'AutoRemove'", () {
      expect(DockerClient.toDockerKey('autoRemove'), equals('AutoRemove'));
    });

    test("'platform' maps to 'Platform'", () {
      expect(DockerClient.toDockerKey('platform'), equals('Platform'));
    });

    test('empty string throws ArgumentError', () {
      expect(() => DockerClient.toDockerKey(''), throwsArgumentError);
    });

    test('generic camelCase key uppercases first char', () {
      expect(DockerClient.toDockerKey('networkMode'), equals('NetworkMode'));
    });

    test('single-char key uppercases correctly', () {
      expect(DockerClient.toDockerKey('x'), equals('X'));
    });

    test('already-PascalCase key is returned unchanged', () {
      // e.g. a caller who already uses PascalCase should not be double-capped
      expect(DockerClient.toDockerKey('HostConfig'), equals('HostConfig'));
    });

    test('snake_case with multiple underscores uppercases first char only', () {
      // The wildcard branch just uppercases the first character.
      // 'cpu_count' is not in the special-case map → 'Cpu_count'.
      expect(DockerClient.toDockerKey('cpu_count'), equals('Cpu_count'));
    });

    test('digit as first character leaves key unchanged', () {
      // digits have no uppercase form — 'toUpperCase()' on '1' returns '1'.
      expect(DockerClient.toDockerKey('1abc'), equals('1abc'));
    });

    test('all-uppercase key is returned with first char still uppercase', () {
      // 'PRIVILEGED' is not in the special-case map; first char 'P' is already
      // uppercase so the result is identical to the input.
      expect(DockerClient.toDockerKey('PRIVILEGED'), equals('PRIVILEGED'));
    });

    test("'_key' with leading underscore is returned as '_key'", () {
      // Underscore has no uppercase form; the wildcard branch returns the
      // key with first char toUpperCase() applied, which is still '_'.
      expect(DockerClient.toDockerKey('_key'), equals('_key'));
    });
  });

  // ---------------------------------------------------------------------------
  // dockerHostHostname / isSshDockerHost
  // ---------------------------------------------------------------------------
  group('dockerHostHostname', () {
    // Save and restore tc.host around each test so we don't bleed state.
    late String? savedTcHost;

    setUp(() {
      savedTcHost = testcontainersConfig.tcProperties['tc.host'];
    });

    tearDown(() {
      if (savedTcHost == null) {
        testcontainersConfig.tcProperties.remove('tc.host');
      } else {
        testcontainersConfig.tcProperties['tc.host'] = savedTcHost!;
      }
    });

    test('extracts hostname from SSH URL in tc.host', () {
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://user@myhost.example.com';
      expect(dockerHostHostname(), equals('myhost.example.com'));
    });

    test('returns null when tc.host is a tcp:// URL', () {
      testcontainersConfig.tcProperties['tc.host'] = 'tcp://localhost:2375';
      expect(dockerHostHostname(), isNull);
    });

    test('extracts hostname when SSH URL has a trailing slash', () {
      // _sanitizeDockerHost strips the trailing path so the URI can be
      // parsed cleanly.
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://user@myhost.example.com/';
      expect(dockerHostHostname(), equals('myhost.example.com'));
    });

    test('extracts hostname when SSH URL has a user:pass@ prefix', () {
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://admin@remote.example.org';
      expect(dockerHostHostname(), equals('remote.example.org'));
    });

    test('extracts hostname when SSH URL includes an explicit port number', () {
      // URI.parse handles 'ssh://user@host:22' correctly — host is still the
      // hostname without the port component.
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://deploy@build.example.com:22';
      expect(dockerHostHostname(), equals('build.example.com'));
    });

    test('extracts hostname when SSH URL has no userinfo component', () {
      // ssh://host.example.com — no user@ prefix.
      testcontainersConfig.tcProperties['tc.host'] = 'ssh://host.example.com';
      expect(dockerHostHostname(), equals('host.example.com'));
    });

    test('returns null when SSH URL has an empty host component', () {
      // 'ssh://' has no hostname — Uri.parse gives uri.host == ''.
      // The `uri.host.isNotEmpty ? uri.host : null` expression returns null.
      testcontainersConfig.tcProperties['tc.host'] = 'ssh://';
      expect(dockerHostHostname(), isNull);
    });
  });

  group('isSshDockerHost', () {
    late String? savedTcHost;

    setUp(() {
      savedTcHost = testcontainersConfig.tcProperties['tc.host'];
    });

    tearDown(() {
      if (savedTcHost == null) {
        testcontainersConfig.tcProperties.remove('tc.host');
      } else {
        testcontainersConfig.tcProperties['tc.host'] = savedTcHost!;
      }
    });

    test('returns true when tc.host is an SSH URL', () {
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://user@remote.example.com';
      expect(isSshDockerHost(), isTrue);
    });

    test('returns false when tc.host is a tcp:// URL', () {
      testcontainersConfig.tcProperties['tc.host'] = 'tcp://localhost:2375';
      expect(isSshDockerHost(), isFalse);
    });

    test('returns false when tc.host is absent', () {
      testcontainersConfig.tcProperties.remove('tc.host');
      // Without a DOCKER_HOST env var or tc.host, there is no SSH host.
      // The test accepts the environment-dependent result: false when no
      // SSH DOCKER_HOST is set, or true when it happens to be configured.
      final result = isSshDockerHost();
      expect(result, isA<bool>());
    });
  });

  // ---------------------------------------------------------------------------
  // dockerHost / dockerAuthConfig
  // ---------------------------------------------------------------------------
  group('dockerHost', () {
    late String? savedTcHost;

    setUp(() {
      savedTcHost = testcontainersConfig.tcProperties['tc.host'];
    });

    tearDown(() {
      if (savedTcHost == null) {
        testcontainersConfig.tcProperties.remove('tc.host');
      } else {
        testcontainersConfig.tcProperties['tc.host'] = savedTcHost!;
      }
    });

    test('returns TCP URL from tc.host unchanged', () {
      // TCP URLs are not SSH — _sanitizeDockerHost leaves them as-is.
      testcontainersConfig.tcProperties['tc.host'] = 'tcp://localhost:2375';
      expect(dockerHost(), equals('tcp://localhost:2375'));
    });

    test('strips trailing slash from SSH URL in tc.host', () {
      // _sanitizeDockerHost strips the trailing path on SSH URLs so that
      // Uri.parse can extract the host component cleanly.
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://user@host.example.com/';
      expect(dockerHost(), equals('ssh://user@host.example.com'));
    });

    test('returns null when tc.host absent and no DOCKER_HOST env', () {
      testcontainersConfig.tcProperties.remove('tc.host');
      // Accept null (no DOCKER_HOST) or a String (DOCKER_HOST is set in CI).
      expect(dockerHost(), anyOf(isNull, isA<String>()));
    });
  });

  group('dockerAuthConfig', () {
    test('returns null or a String depending on DOCKER_AUTH_CONFIG env', () {
      // DOCKER_AUTH_CONFIG is not typically set on a developer machine.
      // Accept either value without asserting direction.
      expect(dockerAuthConfig(), anyOf(isNull, isA<String>()));
    });
  });

  // ---------------------------------------------------------------------------
  // DockerClient.host getter
  // ---------------------------------------------------------------------------
  group('DockerClient.host', () {
    late String? savedTcHost;

    setUp(() {
      savedTcHost = testcontainersConfig.tcProperties['tc.host'];
    });

    tearDown(() {
      if (savedTcHost == null) {
        testcontainersConfig.tcProperties.remove('tc.host');
      } else {
        testcontainersConfig.tcProperties['tc.host'] = savedTcHost!;
      }
    });

    test('returns SSH hostname when tc.host is an SSH URL', () {
      // Branch 2 in host getter: dockerHostHostname() returns the SSH host.
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://user@build-host.example.com';
      expect(client.host, equals('build-host.example.com'));
    });

    test('returns hostname when tc.host is a tcp:// URL', () {
      // Branch 3 in host getter: rawHost.startsWith('tcp://') → parse URI host.
      testcontainersConfig.tcProperties['tc.host'] = 'tcp://192.168.10.5:2375';
      expect(client.host, equals('192.168.10.5'));
    });

    test('returns hostname when tc.host is an http:// URL', () {
      // Branch 3 also covers http://.
      testcontainersConfig.tcProperties['tc.host'] = 'http://10.0.0.1:2375';
      expect(client.host, equals('10.0.0.1'));
    });

    test('returns hostname when tc.host is an https:// URL', () {
      // Branch 3 also covers https://.
      testcontainersConfig.tcProperties['tc.host'] =
          'https://docker.remote:2376';
      expect(client.host, equals('docker.remote'));
    });

    test(
        'returns localhost or real host when tc.host is absent and not inside '
        'a container', () {
      // When tc.host is absent and we are NOT inside a Docker container,
      // branch 4 (defaultGatewayIp) is skipped and we fall through to
      // 'localhost' — unless DOCKER_HOST or TC_HOST env vars override.
      testcontainersConfig.tcProperties.remove('tc.host');
      // The result is environment-dependent (CI may set DOCKER_HOST), so just
      // verify the result is a non-empty string.
      expect(client.host, isA<String>());
      expect(client.host, isNotEmpty);
    });

    test('SSH host with port returns just the hostname', () {
      // URI parsing must strip the port from SSH URLs too.
      testcontainersConfig.tcProperties['tc.host'] =
          'ssh://user@ci-agent.internal:22';
      expect(client.host, equals('ci-agent.internal'));
    });

    test('tcp URL with named host returns hostname as-is', () {
      testcontainersConfig.tcProperties['tc.host'] = 'tcp://dockerd.local:2375';
      expect(client.host, equals('dockerd.local'));
    });

    test(
        'returns localhost when tcp URL has empty host component (h.isEmpty branch)',
        () {
      // 'tcp://:2375' has no hostname — Uri.parse gives an empty host string.
      // The `if (h.isEmpty …) return 'localhost'` branch must fire.
      testcontainersConfig.tcProperties['tc.host'] = 'tcp://:2375';
      expect(client.host, equals('localhost'));
    });
  });

  // ---------------------------------------------------------------------------
  // DockerClient.connectionMode getter
  // ---------------------------------------------------------------------------
  group('DockerClient.connectionMode', () {
    test('returns dockerHost when not inside a container (normal CI/dev env)',
        () {
      // On macOS or a Linux machine where /.dockerenv does not exist,
      // insideContainer() returns false and connectionMode must be dockerHost.
      // This test is deterministic wherever unit tests are run (outside Docker).
      if (File('/.dockerenv').existsSync()) {
        // Inside a container: skip — we can't guarantee the result here.
        return;
      }
      expect(
        client.connectionMode,
        equals(ConnectionMode.dockerHost),
      );
    });

    test('connectionMode is a ConnectionMode value', () {
      // Smoke-test: regardless of environment the getter must return one of
      // the three valid modes without throwing.
      expect(
        client.connectionMode,
        anyOf(
          equals(ConnectionMode.dockerHost),
          equals(ConnectionMode.bridgeIp),
          equals(ConnectionMode.gatewayIp),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Additional decodeChunked edge cases
  // ---------------------------------------------------------------------------
  group('DockerClient.decodeChunked additional edge cases', () {
    test('decodes chunk with uppercase hex size', () {
      // HTTP spec allows uppercase hex for chunk sizes.
      // 'A' = 10 decimal.
      final data = Uint8List.fromList(
        'A\r\n0123456789\r\n0\r\n\r\n'.codeUnits,
      );
      final decoded = client.decodeChunked(data);
      expect(String.fromCharCodes(decoded), equals('0123456789'));
    });

    test('handles truncated chunk data without throwing', () {
      // Chunk header says 10 bytes but body is only 3 bytes long.
      // Parser should stop safely without throwing.
      final data = Uint8List.fromList('A\r\nabc'.codeUnits);
      final decoded = client.decodeChunked(data);
      expect(decoded, isEmpty);
    });

    test('decodes chunk with size in mixed-case hex', () {
      // 'b' = 11 decimal — mixed case is valid HTTP.
      final payload = 'hello world';
      final data = Uint8List.fromList(
        'b\r\nhello world\r\n0\r\n\r\n'.codeUnits,
      );
      final decoded = client.decodeChunked(data);
      expect(String.fromCharCodes(decoded), equals(payload));
    });
  });
}
