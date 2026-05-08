/// Docker container lifecycle and the Ryuk resource-reaper.
///
/// [DockerContainer] is the primary public API for managing a single container.
/// It uses a fluent builder API for configuration, and exposes [start], [stop],
/// and the static [use] helper for lifecycle management.
///
/// [Reaper] is the singleton that manages the Ryuk side-car container, which
/// is responsible for cleaning up orphaned testcontainers resources after the
/// test process exits.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'config.dart';
import 'docker_client.dart';
import 'exceptions.dart';
import 'inspect.dart';
import 'labels.dart';
import 'network.dart';
import 'transferable.dart';
import 'utils.dart';
import 'wait_strategies.dart';
import 'waiting_utils.dart';

/// A Docker container managed by testcontainers-dart.
///
/// Instantiate with an image name and chain builder methods to configure it,
/// then call [start] to create and start the container. Use [use] for an
/// automatic start + stop with a try/finally guarantee.
///
/// Example:
/// ```dart
/// await DockerContainer.use(
///   DockerContainer('redis:7')
///     .withExposedPorts([6379])
///     .waitingFor(PortWaitStrategy(6379)),
///   (container) async {
///     final port = await container.exposedPort(6379);
///     final client = RedisClient('localhost', port);
///     // ... run tests
///   },
/// );
/// ```
class DockerContainer implements WaitStrategyTarget {
  /// The Docker image name (including optional tag) used to create the
  /// container.
  ///
  /// The [TestcontainersConfiguration.hubImageNamePrefix] is prepended in the
  /// constructor, so if a registry mirror is configured, all image names are
  /// automatically redirected.
  final String image;

  final Map<String, String> _env = {};
  final Map<int, int?> _ports = {};
  final Map<String, ({String bind, String mode})> _volumes = {};
  final Map<String, String> _tmpfs = {};

  /// Environment variables injected into the container.
  ///
  /// Read-only view. Use [withEnv], [withEnvs], and [withEnvFile] to add
  /// entries.
  Map<String, String> get env => Map.unmodifiable(_env);

  /// Port map: container port → optional host port.
  ///
  /// A `null` host port value requests an ephemeral port from the OS.
  /// Read-only view. Use [withBindPorts] and [withExposedPorts] to add entries.
  Map<int, int?> get ports => Map.unmodifiable(_ports);

  /// Volume bind mounts: host path → `(bind: containerPath, mode: 'ro'|'rw')`.
  ///
  /// Read-only view. Use [withVolumeMapping] to add entries.
  Map<String, ({String bind, String mode})> get volumes =>
      Map.unmodifiable(_volumes);

  /// Tmpfs mounts: container path → options string.
  ///
  /// Read-only view. Use [withTmpfsMount] to add entries.
  Map<String, String> get tmpfs => Map.unmodifiable(_tmpfs);

  Object? _command; // String or List<String>
  String? _name;
  Network? _network;
  List<String>? _networkAliases;
  Map<String, Object?> _kwargs = {};
  WaitStrategy? _waitStrategy;
  final List<TransferSpec> _transferableSpecs = [];
  final DockerClient _dockerClient;

  String? _containerId;
  ContainerInspectInfo? _cachedContainerInfo;
  String _cachedStatus = 'not_started';

  /// The command override passed to [withCommand], or `null` when the image's
  /// default entrypoint is used.
  ///
  /// The runtime type is either a [String] or a `List<String>`, depending on
  /// how [withCommand] was called. Use `is String` / `is List<String>` to
  /// distinguish the two forms, or prefer passing a `List<String>` to
  /// [withCommand] for stronger type guarantees.
  Object? get command => _command;

  /// The container name, or `null` when none was set.
  String? get name => _name;

  /// The [Network] the container will be attached to, or `null`.
  Network? get network => _network;

  /// DNS aliases on [network], or `null`.
  ///
  /// Read-only view. Use [withNetworkAliases] to set aliases.
  List<String>? get networkAliases {
    final aliases = _networkAliases;
    return aliases != null ? List.unmodifiable(aliases) : null;
  }

  /// Extra Docker `HostConfig` fields passed to [DockerClient.createContainer].
  ///
  /// Read-only view. Use [withKwargs] to set extra host-config fields.
  Map<String, Object?> get kwargs => Map.unmodifiable(_kwargs);

  /// Creates a [DockerContainer] for [image].
  ///
  /// The [TestcontainersConfiguration.hubImageNamePrefix] is prepended to
  /// [image] automatically.
  ///
  /// An optional [dockerClient] can be injected for testing; the default
  /// reads connection settings from the environment.
  DockerContainer(
    String image, {
    DockerClient? dockerClient,
  })  : image = testcontainersConfig.hubImageNamePrefix + image,
        _dockerClient = dockerClient ?? DockerClient();

  /// Sets a single environment variable [key] to [value].
  ///
  /// Returns `this` for chaining.
  DockerContainer withEnv(String key, String value) {
    _env[key] = value;
    return this;
  }

  /// Merges [variables] into the container's environment map.
  ///
  /// Returns `this` for chaining.
  DockerContainer withEnvs(Map<String, String> variables) {
    _env.addAll(variables);
    return this;
  }

  /// Reads environment variables from a `.env`-style file and merges them
  /// into [env].
  ///
  /// The file is parsed line by line:
  /// - Blank lines and lines starting with `#` are skipped.
  /// - Each line must contain `=`; the part before the first `=` is the key,
  ///   the rest is the value (both are whitespace-stripped).
  /// - `${VAR}` references in values are expanded using variables already
  ///   resolved earlier in the same file (same semantics as `python-dotenv`'s
  ///   `dotenv_values()`).
  ///
  /// Returns `this` for chaining.
  DockerContainer withEnvFile(String envFile) {
    final file = File(envFile);
    final resolved = <String, String>{};
    for (final rawLine in file.readAsLinesSync()) {
      final line = rawLine.trim();
      // Skip blank lines and comments
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final idx = line.indexOf('=');
      if (idx < 0) {
        continue;
      }
      final key = line.substring(0, idx).trim();
      final rawValue = line.substring(idx + 1).trim();
      // Expand ${VAR} references using already-resolved variables (dotenv semantics)
      final value = rawValue.replaceAllMapped(
        RegExp(r'\$\{([^}]+)\}'),
        (m) => resolved[m.group(1)] ?? '',
      );
      resolved[key] = value;
      _env[key] = value;
    }
    return this;
  }

  /// Maps [containerPort] to an optional fixed [hostPort].
  ///
  /// When [hostPort] is `null`, the Docker daemon assigns an ephemeral port.
  ///
  /// Returns `this` for chaining.
  DockerContainer withBindPorts(int containerPort, [int? hostPort]) {
    _ports[containerPort] = hostPort;
    return this;
  }

  /// Exposes each port in [exposedPorts] with an ephemeral host port.
  ///
  /// Equivalent to calling `withBindPorts(p, null)` for each `p`.
  ///
  /// Returns `this` for chaining.
  DockerContainer withExposedPorts(List<int> exposedPorts) {
    for (final p in exposedPorts) {
      _ports[p] = null;
    }
    return this;
  }

  /// Attaches the container to [network].
  ///
  /// Returns `this` for chaining.
  DockerContainer withNetwork(Network network) {
    _network = network;
    return this;
  }

  /// Sets DNS aliases for the container on its [network].
  ///
  /// Returns `this` for chaining.
  DockerContainer withNetworkAliases(List<String> aliases) {
    _networkAliases = List.of(aliases);
    return this;
  }

  /// Overrides the default command run by the container.
  ///
  /// [command] may be a [String] (split on spaces/quotes at runtime) or a
  /// `List<String>` (used as-is). An `assert` checks the type at debug time.
  ///
  /// Returns `this` for chaining.
  DockerContainer withCommand(Object command) {
    assert(
      command is String || command is List<String>,
      'command must be a String or List<String>',
    );
    _command = command;
    return this;
  }

  /// Assigns a fixed name to the container.
  ///
  /// Returns `this` for chaining.
  DockerContainer withName(String name) {
    _name = name;
    return this;
  }

  /// Adds a volume bind mount from [host] to [container] with [mode].
  ///
  /// [mode] should be `'rw'` (read-write) or `'ro'` (read-only).
  ///
  /// Returns `this` for chaining.
  DockerContainer withVolumeMapping(
    String host,
    String container,
    String mode,
  ) {
    _volumes[host] = (bind: container, mode: mode);
    return this;
  }

  /// Adds a tmpfs mount at [containerPath].
  ///
  /// [size] is an optional size string in the Docker format (e.g. `'64m'`).
  /// An empty string means no size limit.
  ///
  /// Returns `this` for chaining.
  DockerContainer withTmpfsMount(String containerPath, {String? size}) {
    _tmpfs[containerPath] = size ?? '';
    return this;
  }

  /// Merges [kwargs] into the extra Docker `HostConfig` fields.
  ///
  /// Existing keys are overwritten; keys not present in [kwargs] are
  /// preserved. Keys use Dart camelCase or snake_case naming and are
  /// automatically converted to PascalCase Docker API keys. Known
  /// conversions: `'privileged'` → `'Privileged'`,
  /// `'auto_remove'`/`'autoRemove'` → `'AutoRemove'`,
  /// `'platform'` → `'Platform'`. All other keys have only their first
  /// character upper-cased.
  ///
  /// Returns `this` for chaining.
  DockerContainer withKwargs(Map<String, Object?> kwargs) {
    _kwargs = {..._kwargs, ...kwargs};
    return this;
  }

  /// Attaches a [WaitStrategy] that [start] will invoke after the container
  /// is running.
  ///
  /// Returns `this` for chaining.
  DockerContainer waitingFor(WaitStrategy strategy) {
    _waitStrategy = strategy;
    return this;
  }

  /// Schedules [transferable] to be copied into the container at `destination`
  /// with Unix permission [mode] when [start] is called.
  ///
  /// The copy happens after the container is created but before [start]
  /// invokes the wait strategy.
  ///
  /// Returns `this` for chaining.
  DockerContainer withCopyIntoContainer(
    Transferable transferable,
    String destination,
    int mode,
  ) {
    _transferableSpecs.add((transferable, destination, mode));
    return this;
  }

  /// Conditionally adds `platform: 'linux/amd64'` emulation when running on
  /// an ARM64 host (e.g. Apple Silicon).
  ///
  /// No-ops on x86-64, when emulation is already configured (`'platform'` key
  /// already present in [kwargs]), or when the current platform is not ARM.
  ///
  /// Returns `this` for chaining.
  DockerContainer maybeEmulateAmd64() {
    if (isArm() && !_kwargs.containsKey('platform')) {
      return withKwargs({'platform': 'linux/amd64'});
    }
    return this;
  }

  /// Creates and starts the container, then runs the wait strategy.
  ///
  /// Steps:
  /// 1. Ensures [Reaper] is running (unless Ryuk is disabled).
  /// 2. Calls [configure] (override hook for subclasses).
  /// 3. Creates the container via [DockerClient.createContainer].
  /// 4. Copies any [_transferableSpecs] into the container.
  /// 5. Starts the container via [DockerClient.startContainer].
  /// 6. Runs [_waitStrategy] if one was set.
  ///
  /// Returns `this` after startup is complete.
  ///
  /// Throws [ContainerStartException] or `HttpException` on failure.
  Future<DockerContainer> start() async {
    if (!testcontainersConfig.ryukDisabled &&
        image != testcontainersConfig.ryukImage) {
      await Reaper.getInstance();
    }

    configure();

    final containerId = await _dockerClient.createContainer(
      image,
      command: switch (_command) {
        null => null,
        final List<String> list => list,
        final String cmd => splitCommand(cmd),
        _ => throw ArgumentError(
            'command must be a String or List<String>, got ${_command.runtimeType}',
          ),
      },
      env: _env,
      name: _name,
      ports: _ports,
      volumes: _volumes,
      tmpfs: _tmpfs.isNotEmpty ? _tmpfs : null,
      network: _network?.name,
      networkAliases: _networkAliases,
      kwargs: _kwargs.isNotEmpty ? _kwargs : null,
    );
    _containerId = containerId;

    for (final spec in _transferableSpecs) {
      await _transferIntoContainer(spec.$1, spec.$2, spec.$3);
    }

    await _dockerClient.startContainer(containerId);
    _cachedStatus = 'running';

    await _waitStrategy?.waitUntilReady(this);

    return this;
  }

  /// Removes the container.
  ///
  /// Parameters:
  /// - [force] — send SIGKILL if the container is still running. Default:
  ///   `true`.
  /// - [deleteVolume] — remove anonymous volumes attached to the container.
  ///   Default: `true`.
  ///
  /// No-ops when the container was never started.
  Future<void> stop({bool force = true, bool deleteVolume = true}) async {
    if (_containerId != null) {
      await _dockerClient.removeContainer(
        _containerId!,
        force: force,
        removeVolumes: deleteVolume,
      );
    }
  }

  /// Returns the host IP address through which this container is reachable.
  ///
  /// Delegates to [DockerClient.connectionMode] and then queries the
  /// appropriate address ([DockerClient.host], [DockerClient.gatewayIp], or
  /// [DockerClient.bridgeIp]).
  @override
  Future<String> containerHostIp() async {
    final mode = _dockerClient.connectionMode;
    if (_containerId == null) {
      return 'localhost';
    }
    return switch (mode) {
      ConnectionMode.dockerHost => _dockerClient.host,
      ConnectionMode.gatewayIp => _dockerClient.gatewayIp(_requireContainerId),
      ConnectionMode.bridgeIp => _dockerClient.bridgeIp(_requireContainerId),
    };
  }

  /// Returns the host port mapped to container [port].
  ///
  /// When [ConnectionMode.useMappedPort] is `true`, queries the Docker daemon
  /// for the ephemeral port. Otherwise returns [port] as-is.
  @override
  Future<int> exposedPort(int port) async {
    if (_dockerClient.connectionMode.useMappedPort) {
      if (_containerId == null) {
        return port;
      }
      return _dockerClient.port(_containerId!, port);
    }
    return port;
  }

  /// Returns `this` (the [DockerContainer] instance itself).
  @override
  Object get wrappedContainer => this;

  /// Returns the container's current log output as `(stdout, stderr)`.
  ///
  /// Throws [ContainerStartException] when called before [start].
  @override
  Future<(Uint8List, Uint8List)> logs() async {
    return _dockerClient.logs(_requireContainerId);
  }

  /// Refreshes the cached container status from the Docker daemon.
  ///
  /// No-ops when the container has not been started yet.
  @override
  Future<void> reload() async {
    if (_containerId == null) {
      return;
    }
    try {
      final details = await _dockerClient.containerDetails(_requireContainerId);
      final state = details['State'] as Map<String, dynamic>?;
      _cachedStatus = state?['Status'] as String? ?? 'unknown';
      _cachedContainerInfo = null;
    } catch (e, st) {
      stderr.writeln(
        'testcontainers: error refreshing container status: $e\n$st',
      );
      _cachedStatus = 'unknown';
    }
  }

  /// The most recently refreshed container lifecycle status string.
  ///
  /// Returns `'not_started'` before [start] is called. Possible values after
  /// startup: `'running'`, `'exited'`, `'paused'`, `'restarting'`, `'dead'`,
  /// or `'unknown'`.
  @override
  String get status => _cachedStatus;

  /// Runs [command] inside the running container and returns its result.
  ///
  /// Returns `(exitCode, combinedOutputBytes)`.
  ///
  /// Throws [ContainerStartException] when called before [start].
  @override
  Future<(int, Uint8List)> exec(List<String> command) =>
      _dockerClient.execInContainer(_requireContainerId, command);

  /// Runs a shell command string inside the running container.
  ///
  /// The [command] string is split into tokens (respecting single- and
  /// double-quoted groups) and forwarded to [exec].
  ///
  /// Returns `(exitCode, combinedOutputBytes)`.
  ///
  /// Throws [ContainerStartException] when called before [start].
  Future<(int, Uint8List)> execShell(String command) =>
      exec(splitCommand(command));

  /// Blocks until the container stops and returns its exit code.
  ///
  /// Useful for containers that are expected to run to completion (e.g. init
  /// or migration containers).
  ///
  /// Throws [ContainerStartException] when called before [start].
  Future<int> wait() async {
    return _dockerClient.waitContainer(_requireContainerId);
  }

  /// Copies [transferable] into the running container immediately.
  ///
  /// Unlike [withCopyIntoContainer] (which schedules the copy for [start]),
  /// this method can be called at any point after [start] returns.
  ///
  /// [mode] defaults to [kDefaultTransferMode] (`0o644`).
  Future<void> copyIntoContainer(
    Transferable transferable,
    String destination, [
    int mode = kDefaultTransferMode,
  ]) =>
      _transferIntoContainer(transferable, destination, mode);

  /// Downloads [sourceInContainer] from the container and writes it to
  /// [destinationOnHost] as a raw tar file.
  ///
  /// Throws [ContainerStartException] when called before [start].
  Future<void> copyFromContainer(
    String sourceInContainer,
    String destinationOnHost,
  ) async {
    final tarData = await _dockerClient.archive(
      _requireContainerId,
      sourceInContainer,
    );
    final destFile = File(destinationOnHost);
    await destFile.writeAsBytes(tarData);
  }

  /// Returns the underlying [DockerClient] instance.
  ///
  /// Useful when a test or subclass needs to make additional Docker API calls
  /// that are not exposed directly on [DockerContainer].
  DockerClient get dockerClient => _dockerClient;

  /// Returns detailed inspect information for this container.
  ///
  /// The result is cached after the first successful call. Returns `null`
  /// when the container has not been started yet or the inspect call fails.
  @override
  Future<ContainerInspectInfo?> containerInfo() async {
    if (_cachedContainerInfo != null) {
      return _cachedContainerInfo;
    }
    if (_containerId == null) {
      return null;
    }
    try {
      _cachedContainerInfo =
          await _dockerClient.containerInspectInfo(_requireContainerId);
    } catch (e, st) {
      stderr.writeln('testcontainers: error fetching container info: $e\n$st');
      _cachedContainerInfo = null;
    }
    return _cachedContainerInfo;
  }

  /// Packs [transferable] into a tar archive and uploads it to the container
  /// at `/{destination}`.
  Future<void> _transferIntoContainer(
    Transferable transferable,
    String destination,
    int mode,
  ) async {
    final tarData = buildTransferTar(transferable, destination, mode: mode);
    await _dockerClient.putArchive(_requireContainerId, '/', tarData);
  }

  /// Extension hook called by [start] just before the container is created.
  ///
  /// Override in subclasses to inject additional configuration that depends
  /// on state set up after construction (for example, setting environment
  /// variables that are derived from constructor parameters).
  ///
  /// The default implementation is a no-op. Subclasses in separate packages
  /// (e.g. a `PostgresContainer`) should `@override` this method and call
  /// [withEnv] / [withExposedPorts] / etc. before `super.configure()`.
  ///
  /// Example:
  /// ```dart
  /// class PostgresContainer extends DockerContainer {
  ///   PostgresContainer() : super('postgres:16');
  ///
  ///   @override
  ///   void configure() {
  ///     withEnv('POSTGRES_PASSWORD', 'test');
  ///     super.configure();
  ///   }
  /// }
  /// ```
  @protected
  void configure() {}

  /// Returns the container ID, throwing [ContainerStartException] if the
  /// container has not been started yet.
  String get _requireContainerId {
    final id = _containerId;
    if (id == null) {
      throw const ContainerStartException('Container must be started first.');
    }
    return id;
  }

  /// Splits a shell command string into tokens.
  ///
  /// Handles single-quoted (`'…'`) and double-quoted (`"…"`) groups so that
  /// arguments containing spaces can be expressed as a single string:
  /// `'nginx -c "/etc/nginx/nginx.conf"'` → `['nginx', '-c', '/etc/nginx/nginx.conf']`.
  ///
  /// Exposed for testing only. Prefer [withCommand] with a `List<String>`
  /// for production use.
  @visibleForTesting
  static List<String> splitCommand(String command) {
    final result = <String>[];
    final current = StringBuffer();
    var inSingleQuote = false;
    var inDoubleQuote = false;
    for (var i = 0; i < command.length; i++) {
      final char = command[i];
      if (inSingleQuote) {
        if (char == "'") {
          inSingleQuote = false;
        } else {
          current.write(char);
        }
      } else if (inDoubleQuote) {
        if (char == '"') {
          inDoubleQuote = false;
        } else {
          current.write(char);
        }
      } else if (char == "'") {
        inSingleQuote = true;
      } else if (char == '"') {
        inDoubleQuote = true;
      } else if (char == ' ' || char == '\t') {
        if (current.isNotEmpty) {
          result.add(current.toString());
          current.clear();
        }
      } else {
        current.write(char);
      }
    }
    if (current.isNotEmpty) {
      result.add(current.toString());
    }
    return result;
  }

  /// Starts [container], runs [fn] with it, and stops it afterwards.
  ///
  /// The container is stopped even if [fn] throws. This is the recommended
  /// idiom for using containers in tests:
  ///
  /// ```dart
  /// await DockerContainer.use(
  ///   DockerContainer('postgres:16').withExposedPorts([5432]),
  ///   (pg) async {
  ///     final port = await pg.exposedPort(5432);
  ///     // run tests
  ///   },
  /// );
  /// ```
  static Future<T> use<T>(
    DockerContainer container,
    Future<T> Function(DockerContainer) fn,
  ) async {
    await container.start();
    try {
      return await fn(container);
    } finally {
      await container.stop();
    }
  }
}

/// Singleton that manages the Ryuk resource-reaper side-car container.
///
/// Ryuk is a small Docker helper that listens on a TCP socket and removes all
/// Docker resources labelled with the current session ID when the TCP
/// connection is dropped (i.e. when the test process exits). This ensures
/// that containers, networks, and volumes do not accumulate even when the test
/// process crashes.
///
/// [Reaper] is created lazily on the first call to [getInstance]. It starts
/// the Ryuk container, establishes a persistent TCP connection, and sends the
/// session-ID label registration message.
///
/// Lifecycle:
/// - [getInstance] — create or return the existing singleton.
/// - [deleteInstance] — close the Ryuk socket and remove the Ryuk container
///   (used in tests that need a clean slate).
class Reaper {
  static DockerContainer? _container;
  static RawSocket? _socket;

  // Memoised future: ensures _createInstance is called at most once even
  // when multiple callers await getInstance() concurrently in the same
  // isolate before initialisation completes.
  static Future<Reaper>? _initFuture;

  /// Returns the singleton [Reaper], creating it if necessary.
  ///
  /// On first call, starts the Ryuk container, waits for it to become ready,
  /// connects a TCP socket, and sends the session-ID registration message.
  ///
  /// Concurrent calls that arrive before initialisation completes share the
  /// same [Future] and will all receive the same [Reaper] instance.
  ///
  /// Throws [ContainerConnectException] when the Ryuk container's host/port
  /// cannot be determined, or when all 50 TCP connection attempts fail.
  static Future<Reaper> getInstance() =>
      _initFuture ??= _createInstance();

  /// Closes the Ryuk TCP socket and removes the Ryuk container.
  ///
  /// Resets the singleton so that [getInstance] will create a fresh instance
  /// on the next call. Used in test teardown to isolate test sessions.
  static Future<void> deleteInstance() async {
    _initFuture = null;
    final socket = _socket;
    if (socket != null) {
      await socket.close();
      _socket = null;
    }
    final container = _container;
    if (container != null) {
      try {
        await container.stop();
      } catch (e) {
        stderr.writeln('testcontainers: error stopping Ryuk container: $e');
      }
      _container = null;
    }
  }

  static Future<Reaper> _createInstance() async {
    final ryukContainer = DockerContainer(testcontainersConfig.ryukImage)
        .withName('testcontainers-ryuk-$sessionId')
        .withExposedPorts([8080])
        .withVolumeMapping(
          testcontainersConfig.ryukDockerSocket,
          '/var/run/docker.sock',
          'rw',
        )
        .withKwargs({
          'privileged': testcontainersConfig.ryukPrivileged,
          'auto_remove': true,
        })
        .withEnv(
          'RYUK_RECONNECTION_TIMEOUT',
          testcontainersConfig.ryukReconnectionTimeout,
        )
        .waitingFor(
          LogMessageWaitStrategy(RegExp(r'.* Started!'))
            ..withStartupTimeout(const Duration(seconds: 20)),
        );

    await ryukContainer.start();
    _container = ryukContainer;

    final containerHost = await ryukContainer.containerHostIp();
    final containerPort = await ryukContainer.exposedPort(8080);

    if (containerHost.isEmpty || containerPort == 0) {
      throw ContainerConnectException(
        'Could not obtain network details for ryuk container. '
        'Host: $containerHost Port: $containerPort',
      );
    }

    Exception? lastException;
    for (var i = 0; i < 50; i++) {
      try {
        final socket = await RawSocket.connect(containerHost, containerPort)
            .timeout(const Duration(seconds: 1));
        _socket = socket;
        lastException = null;
        break;
      } catch (e) {
        lastException = e is Exception ? e : Exception(e.toString());
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    if (lastException != null) {
      throw lastException;
    }

    // Send the session-ID label registration message exactly as the Ryuk
    // protocol requires: 'label=org.testcontainers.session-id=<uuid>\r\n'
    final msg = 'label=$labelSessionId=$sessionId\r\n';
    // _socket is non-null here: the loop above either assigned it or threw.
    _socket!.write(utf8.encode(msg));

    return Reaper._();
  }

  Reaper._();
}
