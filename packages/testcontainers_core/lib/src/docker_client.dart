/// Low-level Docker Engine API client.
///
/// [DockerClient] communicates with the Docker daemon over a Unix domain
/// socket (the default) or a TCP/HTTP connection. All HTTP is done at the
/// raw socket level using HTTP/1.0 so that each request opens and closes its
/// own connection — no keep-alive complexity.
///
/// The public API mirrors the subset of the Docker Engine REST API used by
/// testcontainers-dart:
/// - Container lifecycle: create, start, stop, remove, exec, wait, inspect
/// - Image management: pull, build, remove
/// - Network management: create, remove, connect
/// - File transfer: put/get archive (tar over the Docker API)
/// - Log streaming
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'auth.dart';
import 'config.dart';
import 'inspect.dart';
import 'labels.dart';
import 'utils.dart';

/// Returns the effective Docker host from the configuration or environment.
///
/// Resolution order:
/// 1. `tc.host` key in `~/.testcontainers.properties`
/// 2. `DOCKER_HOST` environment variable
///
/// The returned string is sanitised: `ssh://user@host/` trailing slashes are
/// removed so that the URI is well-formed.
///
/// Returns `null` when neither source is set.
String? dockerHost() {
  final host =
      testcontainersConfig.tcHost ?? Platform.environment['DOCKER_HOST'];
  if (host == null) {
    return null;
  }
  return _sanitizeDockerHost(host);
}

/// Returns the hostname portion of an SSH-based Docker host URL.
///
/// For example, `ssh://user@myhost.example.com` returns
/// `'myhost.example.com'`.
///
/// Returns `null` when [dockerHost] is not an SSH URL or the host
/// component is empty.
String? dockerHostHostname() {
  final rawHost = dockerHost();
  if (rawHost == null || !rawHost.startsWith('ssh://')) {
    return null;
  }
  final uri = Uri.parse(rawHost);
  return uri.host.isNotEmpty ? uri.host : null;
}

/// Returns `true` when the Docker host is reached via SSH.
///
/// This affects port normalisation in `PublishedPortModel.normalize`: loopback
/// addresses are replaced with the remote hostname so that tests running on
/// the local machine can reach ports inside containers on the remote host.
bool isSshDockerHost() => dockerHostHostname() != null;

/// Returns the raw `DOCKER_AUTH_CONFIG` string, or `null`.
///
/// Used by [DockerClient] to authenticate against private registries when
/// pulling or pushing images.
String? dockerAuthConfig() => testcontainersConfig.dockerAuthConfig;

String _sanitizeDockerHost(String host) {
  if (!host.startsWith('ssh://')) {
    return host;
  }
  final uri = Uri.parse(host);
  if (uri.path.isNotEmpty) {
    return uri.replace(path: '').toString();
  }
  return host;
}

/// Default Docker daemon TCP port when no explicit port is in `DOCKER_HOST`.
const int _defaultDockerTcpPort = 2375;

/// ASCII carriage-return byte value used in HTTP/1.x CRLF sequences.
const int _cr = 13;

/// ASCII line-feed byte value used in HTTP/1.x CRLF sequences.
const int _lf = 10;

// POSIX tar header layout constants (ustar format).
/// Size of a single POSIX tar block in bytes.
const int _tarBlockSize = 512;

/// Maximum byte length of a filename field in a POSIX tar header.
const int _tarNameFieldSize = 100;

/// Byte offset of the file-size field in a POSIX tar header.
const int _tarSizeOffset = 124;

/// Width (in characters) of the octal size field in a POSIX tar header.
const int _tarSizeFieldWidth = 11;

/// Byte offset of the link-indicator / type-flag field in a POSIX tar header.
const int _tarTypeFlagOffset = 156;

/// Byte offset of the checksum field in a POSIX tar header.
const int _tarChecksumOffset = 148;

/// ASCII byte value for the character `'0'` (regular-file type flag).
const int _tarRegularFileType = 48;

/// Internal value type wrapping a raw HTTP response.
class _DockerResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  const _DockerResponse(this.statusCode, this.headers, this.body);

  /// Decodes [body] as a UTF-8 string, replacing malformed sequences.
  String get bodyString => utf8.decode(body, allowMalformed: true);

  /// Parses [bodyString] as JSON.
  Object? get bodyJson => jsonDecode(bodyString);
}

/// A thin HTTP client that speaks directly to the Docker Engine API.
///
/// By default, [DockerClient] uses a Unix domain socket (path determined by
/// [dockerSocket]) and targets API version `v1.41`. When `DOCKER_HOST`
/// is set to a `tcp://` or `http://` URL, a plain TCP connection is used
/// instead.
///
/// Instances are stateless (no persistent connection pool) — each method call
/// opens and closes its own socket connection.
///
/// Example:
/// ```dart
/// final client = DockerClient();
/// final id = await client.createContainer('nginx:alpine-slim',
///   ports: {80: null});
/// await client.startContainer(id);
/// final port = await client.port(id, 80);
/// print('nginx is at http://localhost:$port');
/// await client.removeContainer(id, force: true);
/// ```
class DockerClient {
  final String _socketPath;
  final bool _isTcp;

  /// Creates a [DockerClient] from the environment.
  ///
  /// Connection parameters are read from `DOCKER_HOST`,
  /// `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`, and other standard env vars via
  /// [dockerSocket] and [dockerHost].
  ///
  /// If `DOCKER_AUTH_CONFIG` is set, the first registry entry is used to
  /// perform an implicit `POST /auth` login.
  DockerClient() : this._fromEnv();

  DockerClient._fromEnv()
      : _socketPath = dockerSocket(),
        _isTcp = _detectTcp() {
    final authConfig = dockerAuthConfig();
    if (authConfig != null) {
      final auth = parseDockerAuthConfig(authConfig);
      if (auth != null && auth.isNotEmpty) {
        _login(auth.first);
      }
    }
  }

  /// Creates a [DockerClient] with no real socket connection.
  ///
  /// The socket path is set to a non-existent path so that any method that
  /// tries to make an actual Docker API call will fail immediately. This
  /// constructor exists solely to enable unit tests of pure parsing logic
  /// (e.g. [decodeChunked], [stripDockerLogHeaders]) without a Docker daemon.
  @visibleForTesting
  DockerClient.testOnly()
      : _socketPath = '/dev/null',
        _isTcp = false;

  static bool _detectTcp() {
    final rawHost = dockerHost();
    if (rawHost == null) {
      return false;
    }
    return rawHost.startsWith('tcp://') ||
        rawHost.startsWith('http://') ||
        rawHost.startsWith('https://');
  }

  static String? _getTcpHost() {
    final rawHost = dockerHost();
    if (rawHost == null) {
      return null;
    }
    final uri = Uri.parse(rawHost);
    return uri.host;
  }

  static int? _getTcpPort() {
    final rawHost = dockerHost();
    if (rawHost == null) {
      return null;
    }
    final uri = Uri.parse(rawHost);
    return uri.port > 0 ? uri.port : _defaultDockerTcpPort;
  }

  /// Sends an HTTP/1.0 request to the Docker API and returns the response.
  ///
  /// All requests target the `/v1.41` API prefix. A [body] that is a
  /// [Uint8List] is sent as `application/x-tar`; any other value is
  /// JSON-encoded and sent as `application/json`.
  Future<_DockerResponse> _request(
    String method,
    String path, {
    Map<String, String>? queryParams,
    Object? body,
    Map<String, String>? extraHeaders,
  }) async {
    final query = queryParams != null && queryParams.isNotEmpty
        ? '?${queryParams.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}'
        : '';
    final fullPath = '/v1.41$path$query';

    Uint8List? bodyBytes;
    String contentType = 'application/json';
    if (body != null) {
      if (body is Uint8List) {
        bodyBytes = body;
        contentType = 'application/x-tar';
      } else {
        bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      }
    }

    final headers = <String, String>{
      'Host': 'localhost',
      'Connection': 'close',
      'x-tc-sid': sessionId,
      ...?extraHeaders,
    };
    if (bodyBytes != null) {
      headers['Content-Type'] = contentType;
      headers['Content-Length'] = bodyBytes.length.toString();
    }

    if (_isTcp) {
      return _tcpRequest(method, fullPath, headers, bodyBytes);
    }
    return _unixRequest(method, fullPath, headers, bodyBytes);
  }

  /// Sends [method] [path] over a Unix domain socket.
  Future<_DockerResponse> _unixRequest(
    String method,
    String path,
    Map<String, String> headers,
    Uint8List? body,
  ) async {
    final socket = await Socket.connect(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    );
    return _sendOverSocket(socket, method, path, headers, body);
  }

  /// Sends [method] [path] over a plain TCP socket.
  Future<_DockerResponse> _tcpRequest(
    String method,
    String path,
    Map<String, String> headers,
    Uint8List? body,
  ) async {
    final socket = await Socket.connect(
      _getTcpHost() ?? 'localhost',
      _getTcpPort() ?? _defaultDockerTcpPort,
    );
    return _sendOverSocket(socket, method, path, headers, body);
  }

  /// Writes [method] [path] to an already-connected [socket], reads the full
  /// response, closes the socket, and returns a parsed [_DockerResponse].
  ///
  /// Shared by [_unixRequest] and [_tcpRequest] — the only difference between
  /// those two callers is how the socket itself is created.
  Future<_DockerResponse> _sendOverSocket(
    Socket socket,
    String method,
    String path,
    Map<String, String> headers,
    Uint8List? body,
  ) async {
    final sb = StringBuffer()..write('$method $path HTTP/1.0\r\n');
    for (final entry in headers.entries) {
      sb.write('${entry.key}: ${entry.value}\r\n');
    }
    sb.write('\r\n');

    socket.add(utf8.encode(sb.toString()));
    if (body != null) {
      socket.add(body);
    }
    await socket.flush();

    final responseBuilder = BytesBuilder(copy: false);
    await for (final chunk in socket) {
      responseBuilder.add(chunk);
    }
    await socket.close();

    return _parseHttpResponse(responseBuilder.takeBytes());
  }

  /// Parses a raw HTTP/1.0 response byte buffer.
  ///
  /// Handles `Transfer-Encoding: chunked` responses by calling
  /// [_decodeChunked]. Falls back to treating all remaining bytes as the body
  /// for `Content-Length`-based or connection-close responses.
  _DockerResponse _parseHttpResponse(Uint8List bytes) {
    final raw = utf8.decode(bytes, allowMalformed: true);
    final headerEnd = raw.indexOf('\r\n\r\n');
    if (headerEnd < 0) {
      return _DockerResponse(500, {}, bytes);
    }

    final headerSection = raw.substring(0, headerEnd);
    final lines = headerSection.split('\r\n');
    final statusLine = lines.first;
    final statusCode = int.tryParse(statusLine.split(' ')[1]) ?? 500;

    final responseHeaders = <String, String>{};
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx < 0) {
        continue;
      }
      final key = line.substring(0, idx).trim().toLowerCase();
      final value = line.substring(idx + 1).trim();
      responseHeaders[key] = value;
    }

    final bodyStart = headerEnd + 4;
    Uint8List bodyBytes;

    if (responseHeaders['transfer-encoding'] == 'chunked') {
      bodyBytes = _decodeChunked(bytes.sublist(bodyStart));
    } else {
      bodyBytes = bytes.sublist(bodyStart);
    }

    return _DockerResponse(statusCode, responseHeaders, bodyBytes);
  }

  /// Decodes an HTTP chunked-transfer-encoded body.
  Uint8List _decodeChunked(Uint8List data) {
    final builder = BytesBuilder(copy: false);
    var pos = 0;
    while (pos < data.length) {
      final lineEnd = _findCrlf(data, pos);
      if (lineEnd < 0) {
        break;
      }
      final sizeStr =
          utf8.decode(data.sublist(pos, lineEnd), allowMalformed: true).trim();
      final size = int.tryParse(sizeStr, radix: 16) ?? 0;
      if (size == 0) {
        break;
      }
      pos = lineEnd + 2;
      if (pos + size > data.length) {
        break;
      }
      builder.add(data.sublist(pos, pos + size));
      pos += size + 2; // skip CRLF after chunk
    }
    return builder.takeBytes();
  }

  /// Returns the index of the first CRLF (`\r\n`) pair at or after [start].
  ///
  /// Returns `-1` when no CRLF is found.
  int _findCrlf(Uint8List data, int start) {
    for (var i = start; i < data.length - 1; i++) {
      if (data[i] == _cr && data[i + 1] == _lf) {
        return i;
      }
    }
    return -1;
  }

  /// Throws an `HttpException` when [resp] has a 4xx or 5xx status code.
  void _throwIfError(_DockerResponse resp) {
    if (resp.statusCode >= 400) {
      throw HttpException(
        'Docker API error ${resp.statusCode}: ${resp.bodyString}',
      );
    }
  }

  /// Exposed for unit testing — delegates to [_decodeChunked].
  @visibleForTesting
  Uint8List decodeChunked(Uint8List data) => _decodeChunked(data);

  /// Exposed for unit testing — delegates to [_stripDockerLogHeaders].
  @visibleForTesting
  Uint8List stripDockerLogHeaders(Uint8List data) =>
      _stripDockerLogHeaders(data);

  /// Exposed for unit testing — parses a raw HTTP/1.0 response byte buffer.
  ///
  /// Returns a record containing the parsed HTTP status code, the lowercased
  /// response headers, and the decoded body bytes (chunked encoding is
  /// transparently decoded when the `transfer-encoding: chunked` header is
  /// present).
  ///
  /// Returns `(statusCode: 500, headers: {}, body: <original bytes>)` when the
  /// response is malformed (i.e., no `\r\n\r\n` header/body delimiter is
  /// found).
  @visibleForTesting
  ({int statusCode, Map<String, String> headers, Uint8List body})
      parseHttpResponse(Uint8List bytes) {
    final resp = _parseHttpResponse(bytes);
    return (
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: resp.body
    );
  }

  /// Creates a container and returns its ID.
  ///
  /// Sends `POST /containers/create` with the given configuration. The
  /// [createLabels] function is called automatically to stamp the container
  /// with testcontainers metadata labels.
  ///
  /// Parameters:
  /// - [image] — Docker image name (with optional tag).
  /// - [command] — command override. `null` uses the image's default.
  /// - [env] — environment variables as a `KEY → value` map.
  /// - [name] — optional container name.
  /// - [ports] — map of `containerPort → hostPort` (use `null` for an
  ///   ephemeral host port).
  /// - [volumes] — bind mounts: `hostPath → (bind: containerPath, mode: 'ro'|'rw')`.
  /// - [tmpfs] — tmpfs mounts: `containerPath → options string`.
  /// - [labels] — additional Docker labels (must not start with
  ///   `org.testcontainers`).
  /// - [network] — network name or ID to attach the container to.
  /// - [networkAliases] — DNS aliases on [network].
  /// - [kwargs] — extra Docker `HostConfig` fields (camelCase Dart names are
  ///   converted to PascalCase Docker names).
  ///
  /// Returns the new container's full ID string.
  Future<String> createContainer(
    String image, {
    List<String>? command,
    Map<String, String> env = const {},
    String? name,
    Map<int, int?> ports = const {},
    Map<String, ({String bind, String mode})> volumes = const {},
    Map<String, String>? tmpfs,
    Map<String, String>? labels,
    String? network,
    List<String>? networkAliases,
    Map<String, Object?>? kwargs,
  }) async {
    final exposedPorts = <String, dynamic>{};
    final portBindings = <String, dynamic>{};

    for (final entry in ports.entries) {
      final containerPort = '${entry.key}/tcp';
      exposedPorts[containerPort] = {};
      portBindings[containerPort] = [
        {'HostIp': '', 'HostPort': entry.value?.toString() ?? ''},
      ];
    }

    // Extract user-provided labels from kwargs so they don't end up in HostConfig
    final userLabels = kwargs?['labels'] as Map<String, String>? ?? labels;
    final hostConfigKwargs = kwargs != null
        ? (Map<String, Object?>.of(kwargs)..remove('labels'))
        : null;

    final body = <String, Object?>{
      'Image': image,
      'ExposedPorts': exposedPorts,
      'Env': env.entries.map((e) => '${e.key}=${e.value}').toList(),
      'Labels': createLabels(image, userLabels),
      'HostConfig': <String, Object?>{
        'PortBindings': portBindings,
        'Binds': [
          for (final e in volumes.entries)
            '${e.key}:${e.value.bind}:${e.value.mode}',
        ],
        if (tmpfs != null && tmpfs.isNotEmpty) 'Tmpfs': tmpfs,
        if (network != null) 'NetworkMode': network,
        ...?hostConfigKwargs?.map(
          (k, v) => MapEntry(_toDockerKey(k), v),
        ),
      },
      if (command != null) 'Cmd': command,
    };

    if (network != null && networkAliases != null) {
      body['NetworkingConfig'] = {
        'EndpointsConfig': {
          network: {
            'Aliases': networkAliases,
          },
        },
      };
    }

    final queryParams = name != null ? <String, String>{'name': name} : null;
    final resp = await _request(
      'POST',
      '/containers/create',
      queryParams: queryParams,
      body: body,
    );
    _throwIfError(resp);
    final data = resp.bodyJson as Map<String, dynamic>;
    final id = data['Id'] as String?;
    if (id == null || id.isEmpty) {
      throw StateError(
        'Docker API returned a container create response with no Id field. '
        'Response body: ${resp.bodyString}',
      );
    }
    return id;
  }

  /// Converts a Dart-style camelCase or snake_case key to the Docker API's
  /// PascalCase convention.
  ///
  /// Known special cases (`privileged`, `auto_remove`, `autoRemove`,
  /// `platform`) are mapped explicitly. All other keys have their first
  /// character upper-cased.
  ///
  /// Throws [ArgumentError] when [dartKey] is empty.
  ///
  /// Exposed for unit testing via `DockerClient.toDockerKey`.
  @visibleForTesting
  static String toDockerKey(String dartKey) => _toDockerKey(dartKey);

  static String _toDockerKey(String dartKey) {
    if (dartKey.isEmpty) {
      throw ArgumentError.value(dartKey, 'dartKey', 'Key must not be empty');
    }
    return switch (dartKey) {
      'privileged' => 'Privileged',
      'auto_remove' || 'autoRemove' => 'AutoRemove',
      'platform' => 'Platform',
      _ => '${dartKey[0].toUpperCase()}${dartKey.substring(1)}',
    };
  }

  /// Starts a previously created container.
  ///
  /// Sends `POST /containers/{id}/start`.
  /// No-ops when the container is already running (HTTP 304 Not Modified).
  Future<void> startContainer(String id) async {
    final resp = await _request('POST', '/containers/$id/start');
    if (resp.statusCode != 204 && resp.statusCode != 304) {
      _throwIfError(resp);
    }
  }

  /// Stops a running container gracefully.
  ///
  /// Sends a SIGTERM (or the image's configured stop signal) and waits up to
  /// [timeout] seconds before sending SIGKILL.
  ///
  /// Parameters:
  /// - [id] — container ID or name.
  /// - [timeout] — grace period in seconds before force-kill. Default: `10`.
  Future<void> stopContainer(String id, {int timeout = 10}) async {
    final resp = await _request(
      'POST',
      '/containers/$id/stop',
      queryParams: {'t': timeout.toString()},
    );
    if (resp.statusCode != 204 && resp.statusCode != 304) {
      _throwIfError(resp);
    }
  }

  /// Removes a container.
  ///
  /// Parameters:
  /// - [id] — container ID or name.
  /// - [force] — force removal even if the container is running (sends SIGKILL
  ///   first). Default: `false`.
  /// - [removeVolumes] — also remove anonymous volumes attached to the
  ///   container. Default: `false`.
  Future<void> removeContainer(
    String id, {
    bool force = false,
    bool removeVolumes = false,
  }) async {
    final resp = await _request(
      'DELETE',
      '/containers/$id',
      queryParams: {
        'force': force.toString(),
        'v': removeVolumes.toString(),
      },
    );
    if (resp.statusCode != 204) {
      _throwIfError(resp);
    }
  }

  /// Removes an image from the local image cache.
  ///
  /// Parameters:
  /// - [imageId] — full or short image ID, or `name:tag`.
  /// - [force] — remove even if the image is used by stopped containers.
  ///   Default: `true`.
  /// - [noPrune] — do not delete untagged parent images. Default: `false`.
  Future<void> removeImage(
    String imageId, {
    bool force = true,
    bool noPrune = false,
  }) async {
    final resp = await _request(
      'DELETE',
      '/images/$imageId',
      queryParams: {
        'force': force.toString(),
        'noprune': noPrune.toString(),
      },
    );
    if (resp.statusCode != 200 && resp.statusCode != 404) {
      _throwIfError(resp);
    }
  }

  /// Pulls an image from a registry.
  ///
  /// Sends `POST /images/create` with the image name and optional tag. If
  /// [image] contains no `:` tag suffix, `latest` is assumed.
  Future<void> pullImage(String image) async {
    final parts = image.split(':');
    final fromImage = parts.first;
    final tag = parts.length > 1 ? parts.last : 'latest';
    final resp = await _request(
      'POST',
      '/images/create',
      queryParams: {'fromImage': fromImage, 'tag': tag},
    );
    _throwIfError(resp);
  }

  /// Builds an image from a local context directory and returns its ID and
  /// build logs.
  ///
  /// The entire [contextPath] directory is tar-archived in memory and sent
  /// to `POST /build`.
  ///
  /// Parameters:
  /// - [contextPath] — path to the Docker build context.
  /// - [tag] — optional `name:tag` to apply to the built image.
  /// - [noCache] — disable the build cache. Default: `false`.
  /// - [dockerfile] — optional Dockerfile path relative to [contextPath].
  ///
  /// Returns a record `(imageId, logs)` where [imageId] is the built image's
  /// ID (or the [tag] string when the ID cannot be parsed from build output)
  /// and `logs` is the streaming build log as a list of JSON objects.
  Future<(String, List<Map<String, dynamic>>)> buildImage(
    String contextPath, {
    String? tag,
    bool noCache = false,
    String? dockerfile,
  }) async {
    final tarData = _buildContextTar(contextPath);
    final queryParams = <String, String>{
      if (tag != null) 't': tag,
      if (noCache) 'nocache': 'true',
      if (dockerfile != null) 'dockerfile': dockerfile,
    };
    final resp = await _request(
      'POST',
      '/build',
      queryParams: queryParams,
      body: tarData,
    );
    _throwIfError(resp);
    String? imageId;
    final logs = <Map<String, dynamic>>[];
    for (final line in resp.bodyString.split('\n')) {
      if (line.isEmpty) {
        continue;
      }
      try {
        final parsed = jsonDecode(line) as Map<String, dynamic>;
        logs.add(parsed);
        if (parsed['aux'] != null) {
          imageId = (parsed['aux'] as Map<String, dynamic>)['ID'] as String?;
        }
      } catch (_) {}
    }
    return (imageId ?? tag ?? '', logs);
  }

  /// Builds a minimal POSIX tar archive from [contextPath] in memory.
  ///
  /// Only regular files are included. The POSIX header fields written are:
  /// name (100 bytes), size (11 octal digits), type flag (`'0'` = regular),
  /// and checksum. Two 512-byte end-of-archive blocks are appended.
  Uint8List _buildContextTar(String contextPath) {
    final dir = Directory(contextPath);
    final builder = BytesBuilder(copy: false);

    void addFile(File file, String name) {
      final bytes = file.readAsBytesSync();
      final nameBytes = utf8.encode(name);
      final header = List<int>.filled(_tarBlockSize, 0);
      for (var i = 0; i < nameBytes.length && i < _tarNameFieldSize; i++) {
        header[i] = nameBytes[i];
      }
      final sizeOctal =
          bytes.length.toRadixString(8).padLeft(_tarSizeFieldWidth, '0');
      final sizeBytes = utf8.encode(sizeOctal);
      for (var i = 0; i < sizeBytes.length; i++) {
        header[_tarSizeOffset + i] = sizeBytes[i];
      }
      header[_tarTypeFlagOffset] = _tarRegularFileType;
      var checksum = 0;
      for (final b in header) {
        checksum += b;
      }
      final checksumStr = checksum.toRadixString(8).padLeft(6, '0');
      final checksumBytes = utf8.encode('$checksumStr\x00 ');
      for (var i = 0; i < checksumBytes.length; i++) {
        header[_tarChecksumOffset + i] = checksumBytes[i];
      }
      builder.add(header);
      builder.add(bytes);
      final padding =
          (_tarBlockSize - bytes.length % _tarBlockSize) % _tarBlockSize;
      if (padding > 0) {
        builder.add(Uint8List(padding)); // zero-filled padding block
      }
    }

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        final relative = entity.path.substring(contextPath.length + 1);
        addFile(entity, relative);
      }
    }
    // Two 512-byte end-of-archive blocks (POSIX ustar requirement).
    builder.add(Uint8List(_tarBlockSize * 2));
    return builder.takeBytes();
  }

  /// Returns the host port mapped to [port] on [containerId].
  ///
  /// Inspects the container and reads `NetworkSettings.Ports["{port}/tcp"][0].HostPort`.
  ///
  /// Throws [StateError] when the port is not mapped.
  Future<int> port(String containerId, int port) async {
    final resp = await _request('GET', '/containers/$containerId/json');
    _throwIfError(resp);
    final data = resp.bodyJson as Map<String, dynamic>;
    final networkSettings = data['NetworkSettings'] as Map<String, dynamic>?;
    final ports = networkSettings?['Ports'] as Map<String, dynamic>?;
    final key = '$port/tcp';
    final bindings = ports?[key] as List<dynamic>?;
    if (bindings == null || bindings.isEmpty) {
      throw StateError('Port $port not mapped for container $containerId');
    }
    final binding = bindings.first as Map<String, dynamic>;
    return int.parse(binding['HostPort'] as String);
  }

  /// Lists containers.
  ///
  /// Parameters:
  /// - [all] — when `true`, includes stopped containers. Default: `false`.
  /// - [filters] — map of filter criteria (JSON-encoded and passed as
  ///   the `filters` query parameter).
  ///
  /// Returns the raw JSON list from Docker as a list of maps.
  Future<List<Map<String, dynamic>>> containers({
    bool all = false,
    Map<String, dynamic>? filters,
  }) async {
    final queryParams = <String, String>{'all': all.toString()};
    if (filters != null) {
      queryParams['filters'] = jsonEncode(filters);
    }
    final resp = await _request(
      'GET',
      '/containers/json',
      queryParams: queryParams,
    );
    _throwIfError(resp);
    return (resp.bodyJson as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Returns the raw inspect JSON for a single container.
  ///
  /// Sends `GET /containers/{id}/json`. Use [containerInspectInfo] for
  /// a strongly-typed version.
  Future<Map<String, dynamic>> containerDetails(String id) async {
    final resp = await _request('GET', '/containers/$id/json');
    _throwIfError(resp);
    return resp.bodyJson as Map<String, dynamic>;
  }

  /// Returns the bridge-network IP address of [id].
  ///
  /// Reads `NetworkSettings.Networks[mode].IPAddress`, where `mode` is
  /// the container's `NetworkMode` (defaulting to `'bridge'`).
  /// Falls back to `'localhost'` when the address is empty.
  Future<String> bridgeIp(String id) async {
    final details = await containerDetails(id);
    final networkSettings = details['NetworkSettings'] as Map<String, dynamic>;
    final networkMode = (details['HostConfig']
            as Map<String, dynamic>?)?['NetworkMode'] as String? ??
        'bridge';
    final networkName = networkMode == 'default' ? 'bridge' : networkMode;
    final networks = networkSettings['Networks'] as Map<String, dynamic>?;
    final network = networks?[networkName] as Map<String, dynamic>?;
    return network?['IPAddress'] as String? ?? 'localhost';
  }

  /// Returns the gateway IP address of the bridge network for [id].
  ///
  /// Reads `NetworkSettings.Networks[mode].Gateway`. Falls back to
  /// `'localhost'` when the gateway is empty.
  Future<String> gatewayIp(String id) async {
    final details = await containerDetails(id);
    final networkSettings = details['NetworkSettings'] as Map<String, dynamic>;
    final networkMode = (details['HostConfig']
            as Map<String, dynamic>?)?['NetworkMode'] as String? ??
        'bridge';
    final networkName = networkMode == 'default' ? 'bridge' : networkMode;
    final networks = networkSettings['Networks'] as Map<String, dynamic>?;
    final network = networks?[networkName] as Map<String, dynamic>?;
    return network?['Gateway'] as String? ?? 'localhost';
  }

  /// Determines the active [ConnectionMode] for this client.
  ///
  /// Resolution order:
  /// 1. [TestcontainersConfiguration.connectionModeOverride] — explicit
  ///    override.
  /// 2. If NOT inside a container, or the Docker host is remote → `dockerHost`.
  /// 3. If inside a container → `bridgeIp` when the container ID can be
  ///    determined from cgroups, `gatewayIp` otherwise.
  ConnectionMode get connectionMode {
    final override = testcontainersConfig.connectionModeOverride;
    if (override != null) {
      return override;
    }
    const localhosts = {'localhost', '127.0.0.1', '::1'};
    if (!insideContainer() || !localhosts.contains(host)) {
      return ConnectionMode.dockerHost;
    }
    final containerId = runningContainerId();
    if (containerId != null) {
      return ConnectionMode.bridgeIp;
    }
    return ConnectionMode.gatewayIp;
  }

  /// Returns the host address used to reach containers.
  ///
  /// Resolution order:
  /// 1. [TestcontainersConfiguration.tcHostOverride] (explicit override).
  /// 2. SSH Docker host hostname extracted by [dockerHostHostname].
  /// 3. Hostname from a `tcp://`, `http://`, or `https://` `DOCKER_HOST` URL.
  ///    On Windows, Docker's named-pipe host `localnpipe` is normalised to
  ///    `'localhost'`.
  /// 4. Default gateway IP when running inside a container ([defaultGatewayIp]).
  /// 5. `'localhost'` as the final fallback.
  String get host {
    final override = testcontainersConfig.tcHostOverride;
    if (override != null) {
      return override;
    }

    final sshHost = dockerHostHostname();
    if (sshHost != null) {
      return sshHost;
    }

    final rawHost = dockerHost();
    if (rawHost != null) {
      if (rawHost.startsWith('tcp://') ||
          rawHost.startsWith('http://') ||
          rawHost.startsWith('https://')) {
        final uri = Uri.parse(rawHost);
        final h = uri.host;
        if (h.isEmpty || (h == 'localnpipe' && isWindows())) {
          return 'localhost';
        }
        return h;
      }
    }

    if (insideContainer()) {
      final gw = defaultGatewayIp();
      if (gw != null) {
        return gw;
      }
    }
    return 'localhost';
  }

  /// Best-effort fire-and-forget login triggered during construction.
  ///
  /// Schedules a `POST /auth` call via [login] and silently swallows any
  /// error so that auth failures at init time do not prevent the client
  /// from being used for operations on public registries.
  void _login(DockerAuthInfo auth) {
    login(auth).catchError((_) {});
  }

  /// Authenticates with a Docker registry.
  ///
  /// Sends `POST /auth` with the credentials from [auth]. A `200` response
  /// (optionally containing an identity token) indicates success; any 4xx/5xx
  /// status throws `HttpException`.
  ///
  /// Parameters:
  /// - [auth] — registry credentials produced by [parseDockerAuthConfig].
  Future<void> login(DockerAuthInfo auth) async {
    final resp = await _request(
      'POST',
      '/auth',
      body: {
        'username': auth.username,
        'password': auth.password,
        'serveraddress': auth.registry,
      },
    );
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      _throwIfError(resp);
    }
  }

  /// Creates a user-defined Docker network.
  ///
  /// The network is labelled with testcontainers metadata via [createLabels].
  ///
  /// Parameters:
  /// - [name] — network name.
  /// - [options] — optional extra body fields merged into the request.
  ///
  /// Returns the Docker-assigned network ID.
  Future<String> createNetwork(
    String name, {
    Map<String, dynamic>? options,
  }) async {
    final body = <String, dynamic>{
      'Name': name,
      'Labels': createLabels('', null),
      ...?options,
    };
    final resp = await _request('POST', '/networks/create', body: body);
    _throwIfError(resp);
    final data = resp.bodyJson as Map<String, dynamic>;
    final id = data['Id'] as String?;
    if (id == null || id.isEmpty) {
      throw StateError(
        'Docker API returned a network create response with no Id field. '
        'Response body: ${resp.bodyString}',
      );
    }
    return id;
  }

  /// Removes a Docker network.
  ///
  /// Parameters:
  /// - [id] — the network ID or name to remove.
  ///
  /// Sends `DELETE /networks/{id}`. Throws `HttpException` on failure.
  Future<void> removeNetwork(String id) async {
    final resp = await _request('DELETE', '/networks/$id');
    if (resp.statusCode != 204) {
      _throwIfError(resp);
    }
  }

  /// Connects [containerId] to [networkId].
  ///
  /// Optional [aliases] are DNS names by which [containerId] will be
  /// reachable by other containers on [networkId].
  Future<void> connectNetwork(
    String networkId,
    String containerId, {
    List<String>? aliases,
  }) async {
    final body = <String, dynamic>{
      'Container': containerId,
      if (aliases != null)
        'EndpointConfig': {
          'Aliases': aliases,
        },
    };
    final resp = await _request(
      'POST',
      '/networks/$networkId/connect',
      body: body,
    );
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      _throwIfError(resp);
    }
  }

  /// Runs [command] inside [id] and returns its exit code and combined output.
  ///
  /// Uses the Docker exec API (`POST /containers/{id}/exec` + start + inspect).
  /// stdout and stderr are both attached; the combined output is returned as
  /// raw bytes in the second element of the record.
  ///
  /// Returns `(exitCode, outputBytes)`.
  Future<(int, Uint8List)> execInContainer(
    String id,
    List<String> command,
  ) async {
    final createResp = await _request(
      'POST',
      '/containers/$id/exec',
      body: {
        'AttachStdout': true,
        'AttachStderr': true,
        'Cmd': command,
      },
    );
    _throwIfError(createResp);
    final execId =
        (createResp.bodyJson as Map<String, dynamic>)['Id'] as String?;
    if (execId == null || execId.isEmpty) {
      throw StateError(
        'Docker API returned an exec create response with no Id field.',
      );
    }

    final startResp = await _request(
      'POST',
      '/exec/$execId/start',
      body: {'Detach': false, 'Tty': false},
    );
    _throwIfError(startResp);

    final inspectResp = await _request('GET', '/exec/$execId/json');
    _throwIfError(inspectResp);
    final inspectData = inspectResp.bodyJson as Map<String, dynamic>;
    final exitCode = inspectData['ExitCode'] as int? ?? 0;

    return (exitCode, startResp.body);
  }

  /// Returns a strongly-typed inspect model for [id].
  ///
  /// Equivalent to calling [containerDetails] and passing the result to
  /// [ContainerInspectInfo.fromJson].
  Future<ContainerInspectInfo> containerInspectInfo(String id) async {
    final details = await containerDetails(id);
    return ContainerInspectInfo.fromJson(details);
  }

  /// Uploads a tar archive to the container's filesystem.
  ///
  /// Sends `PUT /containers/{id}/archive?path={path}` with [tarData] as the
  /// request body. The archive is extracted at [path] inside the container.
  ///
  /// Parameters:
  /// - [id] — container ID.
  /// - [path] — destination directory inside the container (e.g. `'/'`).
  /// - [tarData] — raw tar bytes (as produced by [buildTransferTar]).
  Future<void> putArchive(
    String id,
    String path,
    Uint8List tarData,
  ) async {
    final resp = await _request(
      'PUT',
      '/containers/$id/archive',
      queryParams: {'path': path},
      body: tarData,
    );
    if (resp.statusCode != 200 && resp.statusCode != 204) {
      _throwIfError(resp);
    }
  }

  /// Downloads a file or directory from the container's filesystem as a tar
  /// archive.
  ///
  /// Sends `GET /containers/{id}/archive?path={path}` and returns the raw
  /// tar bytes.
  Future<Uint8List> archive(String id, String path) async {
    final resp = await _request(
      'GET',
      '/containers/$id/archive',
      queryParams: {'path': path},
    );
    _throwIfError(resp);
    return resp.body;
  }

  /// Blocks until the container stops and returns its exit code.
  ///
  /// Sends `POST /containers/{id}/wait`. Use this after detaching from a
  /// container to collect its final exit status.
  Future<int> waitContainer(String id) async {
    final resp = await _request('POST', '/containers/$id/wait');
    _throwIfError(resp);
    final json = jsonDecode(utf8.decode(resp.body)) as Map<String, dynamic>;
    return (json['StatusCode'] as num?)?.toInt() ?? 0;
  }

  /// Fetches the container's stdout and stderr log streams.
  ///
  /// Issues two separate requests (`stdout=true` and `stderr=true`) and
  /// strips the 8-byte Docker multiplexed-stream header from each response
  /// before returning the raw log bytes.
  ///
  /// Returns `(stdoutBytes, stderrBytes)`.
  Future<(Uint8List, Uint8List)> logs(String id) async {
    final stdoutResp = await _request(
      'GET',
      '/containers/$id/logs',
      queryParams: {'stdout': 'true', 'stderr': 'false'},
    );
    final stderrResp = await _request(
      'GET',
      '/containers/$id/logs',
      queryParams: {'stdout': 'false', 'stderr': 'true'},
    );
    return (
      _stripDockerLogHeaders(stdoutResp.body),
      _stripDockerLogHeaders(stderrResp.body)
    );
  }

  /// Removes Docker's 8-byte multiplexed log frame headers from [data].
  ///
  /// Each frame starts with 1 byte stream type, 3 bytes padding, and 4 bytes
  /// big-endian payload length. When no valid frames are found, [data] is
  /// returned as-is (compatibility with non-TTY log output).
  Uint8List _stripDockerLogHeaders(Uint8List data) {
    final builder = BytesBuilder(copy: false);
    var pos = 0;
    while (pos + 8 <= data.length) {
      final size = (data[pos + 4] << 24) |
          (data[pos + 5] << 16) |
          (data[pos + 6] << 8) |
          data[pos + 7];
      pos += 8;
      if (pos + size > data.length) {
        break;
      }
      builder.add(data.sublist(pos, pos + size));
      pos += size;
    }
    return builder.isEmpty ? data : builder.takeBytes();
  }
}
