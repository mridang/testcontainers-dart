/// Runtime configuration for testcontainers-dart.
///
/// Configuration is read from two sources (in priority order):
/// 1. Environment variables — standard testcontainers env vars such as
///    `TC_MAX_TRIES`, `TESTCONTAINERS_RYUK_DISABLED`, etc.
/// 2. `~/.testcontainers.properties` — a Java-style `key=value` file
///    read by [readTcProperties].
///
/// The global singleton [testcontainersConfig] is created once at import
/// time and reused throughout the library.
library;

import 'dart:io';

/// Truthy string values accepted when parsing boolean configuration flags.
///
/// Comparisons are always case-insensitive (the incoming string is converted
/// to lower-case before checking membership).
const Set<String> _enableFlags = {'yes', 'true', 't', 'y', '1'};

/// Parses [value] as an integer, throwing [ArgumentError] on failure.
///
/// [envVar] is included in the error message so callers immediately know
/// which environment variable contained the bad value.
int _parseInt(String envVar, String value) {
  final result = int.tryParse(value);
  if (result == null) {
    throw ArgumentError(
      'Invalid value for $envVar: "$value" is not a valid integer.',
    );
  }
  return result;
}

/// Parses [value] as a double, throwing [ArgumentError] on failure.
///
/// [envVar] is included in the error message so callers immediately know
/// which environment variable contained the bad value.
double _parseDouble(String envVar, String value) {
  final result = double.tryParse(value);
  if (result == null) {
    throw ArgumentError(
      'Invalid value for $envVar: "$value" is not a valid number.',
    );
  }
  return result;
}

/// Determines how [DockerClient] computes the host IP address and port for
/// containers.
///
/// The mode is auto-detected based on the running environment but can be
/// overridden via the `TESTCONTAINERS_CONNECTION_MODE` environment variable.
enum ConnectionMode {
  /// Use the container's bridge-network IP address directly.
  ///
  /// Ports are **not** remapped — the container port is used as-is.
  /// Suitable when the test process is running inside the same Docker
  /// network as the container.
  bridgeIp,

  /// Use the default-gateway IP of the Docker bridge network.
  ///
  /// Ports **are** remapped via the Docker daemon's host-port mapping.
  /// Suitable when the test process is in a container on a different
  /// network than the containers under test.
  gatewayIp,

  /// Use the Docker host's address (as resolved by [DockerClient.host]).
  ///
  /// Ports **are** remapped. This is the default mode when the test process
  /// is running directly on the host machine.
  dockerHost;

  /// Returns `true` when this connection mode requires the Docker-assigned
  /// ephemeral host port rather than the container's internal port number.
  bool get useMappedPort => this != ConnectionMode.bridgeIp;
}

/// Returns the path to the Docker Unix socket.
///
/// Resolution order:
/// 1. `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` — explicit socket path.
/// 2. `DOCKER_HOST` starting with `unix://` — custom Unix socket path.
/// 3. `$XDG_RUNTIME_DIR/docker.sock` — rootless Docker socket (if the
///    file exists).
/// 4. `/var/run/docker.sock` — the standard system-wide Docker socket.
String dockerSocket() {
  final override =
      Platform.environment['TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE'];
  if (override != null && override.isNotEmpty) {
    return override;
  }

  // Support unix:// DOCKER_HOST (rootless Docker, custom socket paths)
  final dockerHost = Platform.environment['DOCKER_HOST'] ?? '';
  if (dockerHost.startsWith('unix://')) {
    final socketPath = dockerHost.substring('unix://'.length);
    if (socketPath.isNotEmpty) {
      return socketPath;
    }
  }

  // Try rootless Docker socket via XDG_RUNTIME_DIR
  final xdgRuntimeDir = Platform.environment['XDG_RUNTIME_DIR'];
  if (xdgRuntimeDir != null && xdgRuntimeDir.isNotEmpty) {
    final rootlessSocket = '$xdgRuntimeDir/docker.sock';
    if (File(rootlessSocket).existsSync()) {
      return rootlessSocket;
    }
  }

  return '/var/run/docker.sock';
}

/// Parses the `TESTCONTAINERS_CONNECTION_MODE` environment variable.
///
/// Returns the corresponding [ConnectionMode] value, or `null` when the
/// variable is absent or empty.
///
/// Throws [ArgumentError] when the variable is set to an unrecognised value.
ConnectionMode? overriddenConnectionMode() {
  final val = Platform.environment['TESTCONTAINERS_CONNECTION_MODE'];
  if (val == null || val.isEmpty) {
    return null;
  }
  return switch (val) {
    'bridge_ip' => ConnectionMode.bridgeIp,
    'gateway_ip' => ConnectionMode.gatewayIp,
    'docker_host' => ConnectionMode.dockerHost,
    _ => throw ArgumentError(
        'Error parsing TESTCONTAINERS_CONNECTION_MODE value "$val". '
        'Expected one of: bridge_ip, gateway_ip, docker_host.',
      ),
  };
}

/// Reads `~/.testcontainers.properties` and returns its key-value pairs.
///
/// The file format mirrors the Java `.properties` convention: each non-blank
/// line that contains an `=` character is split on the first `=` and both
/// the key and value are stripped of leading/trailing whitespace. Lines that
/// do not contain `=` are ignored. Quoted values are **not** supported.
///
/// Returns an empty map when the file does not exist.
Map<String, String> readTcProperties() {
  final home = Platform.environment['HOME'] ?? '';
  final file = File('$home/.testcontainers.properties');
  if (!file.existsSync()) {
    return {};
  }
  final settings = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final idx = line.indexOf('=');
    if (idx < 0) {
      continue;
    }
    final key = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    settings[key] = value;
  }
  return settings;
}

/// Holds all runtime-tunable configuration for testcontainers-dart.
///
/// Values are read from environment variables at construction time and can be
/// overridden programmatically (useful in tests). The global singleton
/// [testcontainersConfig] is the authoritative source used throughout the
/// library.
///
/// Example — disable Ryuk in a CI environment:
/// ```dart
/// testcontainersConfig.ryukDisabled = true;
/// ```
class TestcontainersConfiguration {
  /// Creates a configuration object by reading from environment variables
  /// and `~/.testcontainers.properties`.
  ///
  /// This constructor is called once to initialise [testcontainersConfig].
  /// You rarely need to call it directly unless you are constructing a fresh
  /// configuration for testing.
  TestcontainersConfiguration()
      : maxTries = _parseInt(
          'TC_MAX_TRIES',
          Platform.environment['TC_MAX_TRIES'] ?? '120',
        ),
        sleepTime = _parseDouble(
          'TC_POOLING_INTERVAL',
          Platform.environment['TC_POOLING_INTERVAL'] ?? '1',
        ),
        ryukImage = Platform.environment['RYUK_CONTAINER_IMAGE'] ??
            'testcontainers/ryuk:0.8.1',
        ryukReconnectionTimeout =
            Platform.environment['RYUK_RECONNECTION_TIMEOUT'] ?? '10s',
        tcHostOverride = Platform.environment['TC_HOST'] ??
            Platform.environment['TESTCONTAINERS_HOST_OVERRIDE'],
        connectionModeOverride = overriddenConnectionMode(),
        hubImageNamePrefix =
            Platform.environment['TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX'] ?? '',
        dockerAuthConfig = Platform.environment['DOCKER_AUTH_CONFIG'],
        tcProperties = readTcProperties();

  /// Maximum number of polling attempts before a wait strategy gives up.
  ///
  /// Controlled by `TC_MAX_TRIES`. Default: `120`.
  final int maxTries;

  /// Sleep duration in seconds between wait-strategy poll attempts.
  ///
  /// Controlled by `TC_POOLING_INTERVAL`. Default: `1.0`.
  final double sleepTime;

  /// Docker image used to run the Ryuk resource-reaper container.
  ///
  /// Controlled by `RYUK_CONTAINER_IMAGE`.
  /// Default: `'testcontainers/ryuk:0.8.1'`.
  final String ryukImage;

  /// Timeout string passed to Ryuk via the `RYUK_RECONNECTION_TIMEOUT`
  /// environment variable inside the Ryuk container.
  ///
  /// Controlled by `RYUK_RECONNECTION_TIMEOUT`. Default: `'10s'`.
  final String ryukReconnectionTimeout;

  /// Overrides the host address returned by [DockerClient.host].
  ///
  /// Controlled by `TC_HOST` or `TESTCONTAINERS_HOST_OVERRIDE`.
  /// `null` means no override is active.
  final String? tcHostOverride;

  /// Overrides the automatic connection-mode detection.
  ///
  /// Controlled by `TESTCONTAINERS_CONNECTION_MODE`.
  /// `null` means auto-detection is used.
  final ConnectionMode? connectionModeOverride;

  /// Optional prefix prepended to every image name.
  ///
  /// Controlled by `TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX`. Useful in
  /// air-gapped environments with a private registry mirror.
  /// Default: `''` (no prefix).
  final String hubImageNamePrefix;

  /// Properties loaded from `~/.testcontainers.properties`.
  ///
  /// Mutable so tests can inject properties without touching the filesystem.
  final Map<String, String> tcProperties;

  /// Raw JSON string from `DOCKER_AUTH_CONFIG`, or `null`.
  ///
  /// Parsed by [parseDockerAuthConfig] when a [DockerClient] is created.
  String? dockerAuthConfig;

  bool? _ryukPrivileged;
  bool? _ryukDisabled;
  String? _ryukDockerSocket;

  /// The effective startup timeout in seconds: [maxTries] × [sleepTime].
  ///
  /// Used as the default [WaitStrategy.startupTimeout]. Default: `120.0` s.
  double get timeout => maxTries * sleepTime;

  bool _resolveFlag(String envName, String propName) {
    final envVal = Platform.environment[envName];
    if (envVal != null) {
      return _enableFlags.contains(envVal.toLowerCase());
    }
    final propVal = tcProperties[propName];
    if (propVal != null) {
      return _enableFlags.contains(propVal.toLowerCase());
    }
    return false;
  }

  /// Whether the Ryuk container should run with Docker `--privileged` mode.
  ///
  /// Controlled by `TESTCONTAINERS_RYUK_PRIVILEGED` or the
  /// `ryuk.container.privileged` property. Default: `false`.
  ///
  /// Lazily evaluated on first access and cached thereafter.
  bool get ryukPrivileged => _ryukPrivileged ??= _resolveFlag(
        'TESTCONTAINERS_RYUK_PRIVILEGED',
        'ryuk.container.privileged',
      );

  /// Allows overriding [ryukPrivileged] programmatically (e.g. in tests).
  set ryukPrivileged(bool value) {
    _ryukPrivileged = value;
  }

  /// Whether the Ryuk resource-reaper is disabled.
  ///
  /// When `true`, no Ryuk container is started and Docker resources created
  /// during a test run will **not** be cleaned up automatically.
  ///
  /// Controlled by `TESTCONTAINERS_RYUK_DISABLED` or the `ryuk.disabled`
  /// property. Default: `false`.
  ///
  /// Lazily evaluated on first access and cached thereafter.
  bool get ryukDisabled => _ryukDisabled ??=
      _resolveFlag('TESTCONTAINERS_RYUK_DISABLED', 'ryuk.disabled');

  /// Allows overriding [ryukDisabled] programmatically (e.g. in tests).
  set ryukDisabled(bool value) {
    _ryukDisabled = value;
  }

  /// The Docker socket path used by the Ryuk reaper container.
  ///
  /// Defaults to [dockerSocket] on first access. Override via the setter
  /// for testing.
  String get ryukDockerSocket => _ryukDockerSocket ??= dockerSocket();

  /// Allows overriding [ryukDockerSocket] programmatically (e.g. in tests).
  set ryukDockerSocket(String value) => _ryukDockerSocket = value;

  /// Returns the `tc.host` value from `~/.testcontainers.properties`, or `null`.
  String? get tcHost => tcProperties['tc.host'];
}

/// The process-wide testcontainers configuration singleton.
///
/// Constructed once at module initialisation by reading environment variables
/// and `~/.testcontainers.properties`. All library internals read their
/// defaults from this object.
///
/// You can mutate individual fields (e.g. [TestcontainersConfiguration.ryukDisabled])
/// to influence behaviour without restarting the process.
final testcontainersConfig = TestcontainersConfiguration();
