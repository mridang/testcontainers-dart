/// Docker Compose integration for testcontainers-dart.
///
/// [DockerCompose] wraps the `docker compose` CLI to bring up, introspect,
/// and tear down multi-container stacks in tests. [ComposeContainer] models a
/// single running service inside the stack and implements [WaitStrategyTarget]
/// so that all built-in wait strategies work with Compose services.
///
/// Typical usage:
/// ```dart
/// await DockerCompose.use(
///   DockerCompose(context: 'test/fixtures/my_stack'),
///   (compose) async {
///     final web = compose.container('web');
///     final port = web.publisher(byPort: 8080).publishedPort!;
///     final resp = await http.get(Uri.parse('http://localhost:$port/'));
///     expect(resp.statusCode, equals(200));
///   },
/// );
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:testcontainers_core/testcontainers.dart';

// One-shot deprecation warning for getConfig — printed on the first call only.
bool _getConfigWarningPrinted = false;

/// Convenience extension on [ProcessResult] for cleaner stdout/stderr access.
///
/// [ProcessResult.stdout] is typed as `Object?` in `dart:io` because
/// `Process.run` can be configured to return `List<int>` instead of `String`.
/// In testcontainers-dart all subprocess calls use the default UTF-8 decoding,
/// so stdout and stderr are always `String`. These getters surface that
/// contract without requiring explicit `as String` casts at each call site.
extension _ProcessResultX on ProcessResult {
  String get stdoutString => this.stdout.toString();
  String get stderrString => this.stderr.toString();
}

const String _configExperimentalWarning =
    'get_config is experimental, see testcontainers/testcontainers-python#669';

/// Returns an unmodifiable copy of [list], or `null` when [list] is `null`.
List<T>? _unmodifiableOrNull<T>(List<T>? list) =>
    list != null ? List.unmodifiable(list) : null;

/// IP version preference used when selecting a published port URL.
///
/// Passed to [ComposeContainer.publisher] to choose between IPv4 and IPv6
/// bindings when a service publishes a port on both stacks.
///
/// Example:
/// ```dart
/// final pub = container.publisher(
///   byPort: 8080,
///   preferIpVersion: IpVersion.ipv6,
/// );
/// ```
enum IpVersion {
  /// Prefer IPv4 addresses (`A` records).
  ipv4,

  /// Prefer IPv6 addresses (`AAAA` records).
  ipv6,
}

/// Describes a single published port for a Compose service.
///
/// Docker Compose returns port info in its `docker compose ps --format json`
/// output. Each entry maps a container [targetPort] to a host [publishedPort]
/// at host [url].
class PublishedPortModel {
  /// Host IP address or hostname that the port is bound on.
  ///
  /// Typical values: `'0.0.0.0'`, `'127.0.0.1'`, `'::'`, or a specific
  /// interface address.
  final String? url;

  /// Container-side port number.
  final int? targetPort;

  /// Ephemeral port number on the host.
  final int? publishedPort;

  /// Transport protocol, e.g. `'tcp'` or `'udp'`.
  final String? protocol;

  /// Creates a [PublishedPortModel] with the given fields.
  const PublishedPortModel({
    this.url,
    this.targetPort,
    this.publishedPort,
    this.protocol,
  });

  /// Deserialises a [PublishedPortModel] from the Docker Compose JSON output.
  factory PublishedPortModel.fromJson(Map<String, dynamic> json) =>
      PublishedPortModel(
        url: json['URL'] as String?,
        targetPort: json['TargetPort'] as int?,
        publishedPort: json['PublishedPort'] as int?,
        protocol: json['Protocol'] as String?,
      );

  /// Returns a copy of this model with [url] normalised for the current
  /// Docker host.
  ///
  /// Normalisation rules:
  /// - **SSH Docker host** (`DOCKER_HOST=ssh://…`): loopback addresses
  ///   (`0.0.0.0`, `127.0.0.1`, `localhost`, `::`, `::1`) are replaced with
  ///   the SSH host's hostname so that ports are reachable from the local
  ///   machine.
  /// - **Windows**: `0.0.0.0` is replaced with `127.0.0.1`.
  /// - **Other cases**: no change; the original model is returned unchanged.
  PublishedPortModel normalize() {
    var normalizedUrl = url;
    final sshHost = dockerHostHostname();
    if (sshHost != null &&
        (url == '0.0.0.0' ||
            url == '127.0.0.1' ||
            url == 'localhost' ||
            url == '::' ||
            url == '::1')) {
      normalizedUrl = sshHost;
    } else if (Platform.isWindows && url == '0.0.0.0') {
      normalizedUrl = '127.0.0.1';
    }

    if (normalizedUrl == url) {
      return this;
    }
    return PublishedPortModel(
      url: normalizedUrl,
      targetPort: targetPort,
      publishedPort: publishedPort,
      protocol: protocol,
    );
  }
}

/// Returns the single element of [array], or throws the exception produced
/// by [exception] when the list does not have exactly one element.
T _getOnlyElementOrRaise<T>(List<T> array, Exception Function() exception) {
  if (array.length != 1) {
    throw exception();
  }
  return array.first;
}

/// Represents a single running service container within a Docker Compose
/// stack.
///
/// Instances are returned by [DockerCompose.containers] and
/// [DockerCompose.container]. They implement [WaitStrategyTarget] so
/// standard wait strategies ([LogMessageWaitStrategy], [HttpWaitStrategy],
/// etc.) can be used directly with Compose services.
///
/// Example:
/// ```dart
/// final container = compose.container('db');
/// await LogMessageWaitStrategy(RegExp(r'ready for connections'))
///   .waitUntilReady(container);
/// ```
class ComposeContainer implements WaitStrategyTarget {
  /// Docker container ID (short or full hex string).
  final String? id;

  /// Container name as assigned by Docker Compose.
  final String? name;

  /// The command string the container's main process is running.
  ///
  /// This is the `Command` value from `docker compose ps --format json` — the
  /// effective command as shown by `docker ps`, which combines the entrypoint
  /// and cmd arguments. Not necessarily the `ENTRYPOINT` declared in the
  /// Dockerfile.
  final String? command;

  /// Compose project name.
  final String? project;

  /// Compose service name.
  final String? service;

  /// Container state string, e.g. `'running'`, `'exited'`.
  final String? state;

  /// Docker health-check status string.
  final String? health;

  /// Exit code of the container's main process (when stopped).
  final int? exitCode;

  /// Published port mappings for this container, already [PublishedPortModel.normalize]d.
  final List<PublishedPortModel> publishers;

  DockerCompose? _dockerCompose;
  ContainerInspectInfo? _cachedContainerInfo;

  /// Creates a [ComposeContainer] with the given fields.
  ///
  /// [publishers] defaults to an empty list when not supplied.
  ComposeContainer({
    this.id,
    this.name,
    this.command,
    this.project,
    this.service,
    this.state,
    this.health,
    this.exitCode,
    List<PublishedPortModel>? publishers,
  }) : publishers =
            List.unmodifiable(publishers ?? const <PublishedPortModel>[]);

  /// Deserialises a [ComposeContainer] from one row of
  /// `docker compose ps --format json` output.
  ///
  /// Each [PublishedPortModel] in the `Publishers` array is automatically
  /// normalised via [PublishedPortModel.normalize].
  factory ComposeContainer.fromJson(Map<String, dynamic> json) {
    final rawPublishers = json['Publishers'] as List<dynamic>?;
    final publishers = rawPublishers
            ?.map(
              (p) => PublishedPortModel.fromJson(p as Map<String, dynamic>)
                  .normalize(),
            )
            .toList(growable: false) ??
        const <PublishedPortModel>[];
    return ComposeContainer(
      id: json['ID'] as String?,
      name: json['Name'] as String?,
      command: json['Command'] as String?,
      project: json['Project'] as String?,
      service: json['Service'] as String?,
      state: json['State'] as String?,
      health: json['Health'] as String?,
      exitCode: json['ExitCode'] as int?,
      publishers: publishers,
    );
  }

  /// Returns `true` when [r]'s [PublishedPortModel.url] matches the IP
  /// version preference.
  ///
  /// IPv6 detection: a URL containing `':'` is assumed to be an IPv6 address.
  static bool _matchesProtocol(IpVersion prefer, PublishedPortModel r) {
    final rUrl = r.url;
    return (rUrl != null && rUrl.contains(':')) == (prefer == IpVersion.ipv6);
  }

  /// Finds and returns the single [PublishedPortModel] matching the given
  /// filters.
  ///
  /// Parameters:
  /// - [byPort] — filter by [PublishedPortModel.targetPort].
  /// - [byHost] — filter by [PublishedPortModel.url].
  /// - [preferIpVersion] — filter by IP version. Default: [IpVersion.ipv4].
  ///
  /// Throws [NoSuchPortExposed] when no matching publisher is found or when
  /// more than one publisher matches (ambiguous result).
  PublishedPortModel publisher({
    int? byPort,
    String? byHost,
    IpVersion preferIpVersion = IpVersion.ipv4,
  }) {
    var remaining =
        publishers.where((r) => _matchesProtocol(preferIpVersion, r)).toList();

    if (byPort != null) {
      remaining = remaining.where((r) => r.targetPort == byPort).toList();
    }
    if (byHost != null) {
      remaining = remaining.where((r) => r.url == byHost).toList();
    }

    if (remaining.isEmpty) {
      throw NoSuchPortExposed(
        'No publisher found for service $service '
        "(byPort=${byPort ?? 'any'}, byHost=${byHost ?? 'any'}, "
        'preferIpVersion=$preferIpVersion)',
      );
    }

    return _getOnlyElementOrRaise(
      remaining,
      () => NoSuchPortExposed(
        'Ambiguous publisher for service $service: expected exactly 1 '
        'but found ${remaining.length} '
        "(byPort=${byPort ?? 'any'}, byHost=${byHost ?? 'any'}, "
        'preferIpVersion=$preferIpVersion)',
      ),
    );
  }

  /// Always returns `'127.0.0.1'` for Compose containers.
  ///
  /// Port routing for Compose stacks goes through the Docker host's loopback
  /// interface via [PublishedPortModel.publishedPort].
  @override
  Future<String> containerHostIp() async => '127.0.0.1';

  /// Returns [port] unchanged.
  ///
  /// For Compose containers the host port is obtained via [publisher];
  /// this implementation satisfies the [WaitStrategyTarget] interface for
  /// strategies that call [exposedPort] directly.
  @override
  Future<int> exposedPort(int port) async => port;

  /// Returns `this`.
  @override
  Object get wrappedContainer => this;

  /// Returns the service's log output as `(stdout, stderr)`.
  ///
  /// Delegates to [DockerCompose.logs] for the [service] name.
  ///
  /// Throws [StateError] when the parent [DockerCompose] reference or
  /// [service] name is not set.
  @override
  Future<(Uint8List, Uint8List)> logs() async {
    final compose = _dockerCompose;
    final svc = service;
    if (compose == null) {
      throw StateError('DockerCompose reference not set on ComposeContainer');
    }
    if (svc == null) {
      throw StateError('Service name not set on ComposeContainer');
    }
    final (stdout, stderr) = compose.logs([svc]);
    return (
      Uint8List.fromList(utf8.encode(stdout)),
      Uint8List.fromList(utf8.encode(stderr)),
    );
  }

  /// Runs [command] inside this service's container.
  ///
  /// Delegates to [DockerCompose.execInContainer] for the current [service].
  ///
  /// Returns `(exitCode, stdoutBytes)`.
  ///
  /// Throws [StateError] when the parent [DockerCompose] reference or [service]
  /// name is not set.
  @override
  Future<(int, Uint8List)> exec(List<String> command) async {
    final compose = _dockerCompose;
    final svc = service;
    if (compose == null) {
      throw StateError('DockerCompose reference not set on ComposeContainer');
    }
    if (svc == null) {
      throw StateError('Service name not set on ComposeContainer');
    }
    final (stdout, _, exitCode) = compose.execInContainer(
      command,
      serviceName: svc,
    );
    return (exitCode, Uint8List.fromList(utf8.encode(stdout)));
  }

  /// No-op for Compose containers.
  ///
  /// Unlike [DockerContainer], there is no single-service refresh mechanism.
  /// To get the latest state for a service, call [DockerCompose.containers]
  /// and look up the service by name.
  @override
  Future<void> reload() => Future.value();

  /// Returns [state], or `'unknown'` when [state] is `null`.
  @override
  String get status => state ?? 'unknown';

  /// Returns the full Docker inspect information for this container.
  ///
  /// The result is lazily loaded and cached. Returns `null` when the parent
  /// [DockerCompose] reference is absent (e.g. a manually constructed
  /// [ComposeContainer] not obtained from [DockerCompose.containers]) or
  /// when the inspect call fails.
  @override
  Future<ContainerInspectInfo?> containerInfo() async {
    if (_cachedContainerInfo != null) {
      return _cachedContainerInfo;
    }
    final compose = _dockerCompose;
    final containerId = id;
    if (compose == null || containerId == null) return null;
    try {
      _cachedContainerInfo =
          await compose._dockerClient.containerInspectInfo(containerId);
    } catch (_) {
      _cachedContainerInfo = null;
    }
    return _cachedContainerInfo;
  }
}

/// Manages a Docker Compose stack in tests.
///
/// Wraps the `docker compose` CLI to bring up a multi-service stack, wait for
/// services to be healthy, introspect containers, and tear the stack down.
///
/// All Compose CLI commands are run synchronously via [Process.runSync];
/// failures throw [ProcessException].
///
/// Example:
/// ```dart
/// await DockerCompose.use(
///   DockerCompose(
///     context: 'test/fixtures',
///     composeFileName: ['docker-compose.yaml'],
///     pull: true,
///   ),
///   (compose) async {
///     final port = compose
///       .container('nginx')
///       .publisher(byPort: 80)
///       .publishedPort!;
///     final resp = await http.get(Uri.parse('http://localhost:$port/'));
///     expect(resp.statusCode, 200);
///   },
/// );
/// ```
class DockerCompose {
  /// The directory used as the working directory for all Compose commands.
  ///
  /// This is the directory where `docker compose` is invoked, equivalent to
  /// the `context` parameter in testcontainers-python.
  final String context;

  /// Compose file(s) to pass with `-f`.
  ///
  /// `null` uses the default `docker-compose.yaml` / `compose.yaml` discovery.
  final List<String>? composeFileName;

  /// Whether to run `docker compose pull` before `up`.
  ///
  /// Defaults to `false`.
  final bool pull;

  /// Whether to pass `--build` to `docker compose up`.
  ///
  /// Defaults to `false`.
  final bool build;

  /// Whether to wait for services to be healthy.
  ///
  /// When `true`, passes `--wait` to `docker compose up`. When `false`,
  /// passes `--detach`.
  ///
  /// Defaults to `true`.
  final bool wait;

  /// Whether to preserve volumes when stopping.
  ///
  /// When `true`, [stop] uses `docker compose stop`. When `false`, [stop]
  /// uses `docker compose down --volumes`.
  ///
  /// Defaults to `false`.
  final bool keepVolumes;

  /// `--env-file` argument(s) passed to every Compose command.
  final List<String>? envFile;

  /// Optional subset of services to bring up / tear down.
  ///
  /// When `null`, all services in the compose file are managed.
  final List<String>? services;

  /// Path to the `docker` executable, or `null` to use the system `docker`.
  final String? dockerCommandPath;

  /// `--profile` arguments passed to every Compose command.
  final List<String>? profiles;

  /// Whether to pass `--quiet` to `docker compose pull`.
  ///
  /// Defaults to `false`.
  final bool quietPull;

  /// Whether to pass `--quiet-build` to `docker compose up --build`.
  ///
  /// Defaults to `false`.
  final bool quietBuild;

  Map<String, WaitStrategy>? _waitStrategies;
  late final DockerClient _dockerClient = DockerClient();

  /// Creates a [DockerCompose] with the given configuration.
  ///
  /// [composeFileName] and [envFile] each accept a [List<String>?]. Pass
  /// `null` for default Compose file discovery.
  ///
  /// Defensive copies are made of all [List<String>?] parameters so that
  /// external mutations to the caller's lists do not affect this instance.
  DockerCompose({
    required this.context,
    List<String>? composeFileName,
    this.pull = false,
    this.build = false,
    this.wait = true,
    this.keepVolumes = false,
    List<String>? envFile,
    List<String>? services,
    this.dockerCommandPath,
    List<String>? profiles,
    this.quietPull = false,
    this.quietBuild = false,
  })  : composeFileName = _unmodifiableOrNull(composeFileName),
        envFile = _unmodifiableOrNull(envFile),
        services = _unmodifiableOrNull(services),
        profiles = _unmodifiableOrNull(profiles);

  /// The base command prefix shared by all Compose CLI invocations.
  ///
  /// Lazily built and cached as an **unmodifiable** [List<String>]. Includes:
  /// - `[dockerCommandPath, 'compose']` or `['docker', 'compose']`
  /// - `-f <file>` for each [composeFileName] entry
  /// - `--profile <p>` for each [profiles] entry
  /// - `--env-file <e>` for each [envFile] entry
  ///
  /// Copy this list before appending subcommand arguments.
  late final List<String> composeCommandProperty =
      List.unmodifiable(_buildComposeCommand());

  List<String> _buildComposeCommand() => [
        if (dockerCommandPath != null) ...[
          dockerCommandPath!,
          'compose',
        ] else ...[
          'docker',
          'compose',
        ],
        for (final f in composeFileName ?? const <String>[]) ...['-f', f],
        for (final p in profiles ?? const <String>[]) ...['--profile', p],
        for (final e in envFile ?? const <String>[]) ...['--env-file', e],
      ];

  /// Registers per-service [WaitStrategy] instances to run after `up`.
  ///
  /// The map keys are service names; the values are strategies applied in
  /// iteration order. Call this before [start].
  ///
  /// Returns `this` for chaining.
  DockerCompose waitingFor(Map<String, WaitStrategy> strategies) {
    _waitStrategies = strategies;
    return this;
  }

  /// Brings the Compose stack up.
  ///
  /// Steps:
  /// 1. Optionally runs `docker compose pull` when [pull] is `true`.
  /// 2. Runs `docker compose up [--build] [--wait|--detach] [services…]`.
  /// 3. Runs any registered [_waitStrategies] against their respective
  ///    containers.
  ///
  /// Throws [ProcessException] when any Compose command exits with a non-zero
  /// status.
  Future<void> start() async {
    if (pull) {
      _runCommand([
        ...composeCommandProperty,
        'pull',
        if (quietPull) '--quiet',
      ]);
    }

    _runCommand([
      ...composeCommandProperty,
      'up',
      if (build) '--build',
      if (build && quietBuild) '--quiet-build',
      if (wait) '--wait' else '--detach',
      ...?services,
    ]);

    final strategies = _waitStrategies;
    if (strategies != null) {
      for (final entry in strategies.entries) {
        final target = container(entry.key);
        await entry.value.waitUntilReady(target);
      }
    }
  }

  /// Tears the Compose stack down.
  ///
  /// - [down] `true` (default) — runs `docker compose down --volumes`, removing
  ///   containers and their anonymous volumes.
  /// - [down] `false` — runs `docker compose stop`, stopping containers while
  ///   preserving volumes.
  ///
  /// [use] calls `stop(down: !keepVolumes)`, so `keepVolumes: true` in the
  /// constructor is equivalent to calling `stop(down: false)`.
  ///
  /// Throws [ProcessException] when the underlying command fails.
  void stop({bool down = true}) {
    _runCommand(
      down
          ? [...composeCommandProperty, 'down', '--volumes', ...?services]
          : [...composeCommandProperty, 'stop', ...?services],
    );
  }

  /// Returns log output for the specified [services].
  ///
  /// When [services] is omitted or empty, logs for all services in the stack
  /// are returned.
  ///
  /// Parameters:
  /// - [services] — optional service names to filter. Omit or pass an empty
  ///   list to get logs for all services.
  ///
  /// Returns `(stdout, stderr)` — the raw text output from the process.
  ///
  /// Throws [ProcessException] when the underlying command fails.
  (String, String) logs([List<String>? services]) {
    final cmd = [
      ...composeCommandProperty,
      'logs',
      ...?services,
    ];
    final result = _runCommand(cmd);
    return (result.stdoutString, result.stderrString);
  }

  /// **Experimental.** Returns the resolved Compose configuration as a JSON map.
  ///
  /// A deprecation warning is printed to [stderr] on the first call. The output
  /// format may change between Docker Compose versions.
  ///
  /// Runs `docker compose config --format json` with optional flags:
  /// - [pathResolution] — pass `--no-path-resolution` when `false`. Default: `true`.
  /// - [normalize] — pass `--no-normalize` when `false`. Default: `true`.
  /// - [interpolate] — pass `--no-interpolate` when `false`. Default: `true`.
  ///
  /// Throws [ProcessException] when the underlying command fails.
  Map<String, dynamic> config({
    bool pathResolution = true,
    bool normalize = true,
    bool interpolate = true,
  }) {
    if (!_getConfigWarningPrinted) {
      stderr.writeln(_configExperimentalWarning);
      _getConfigWarningPrinted = true;
    }
    final result = _runCommand([
      ...composeCommandProperty,
      'config',
      '--format',
      'json',
      if (!pathResolution) '--no-path-resolution',
      if (!normalize) '--no-normalize',
      if (!interpolate) '--no-interpolate',
    ]);
    return jsonDecode(result.stdoutString) as Map<String, dynamic>;
  }

  /// Returns the list of containers in the stack.
  ///
  /// Runs `docker compose ps --format json`. Handles both the Docker 24
  /// array-per-output format and the Docker 25+ one-object-per-line format.
  ///
  /// Parameters:
  /// - [includeAll] — when `true`, includes stopped containers (`-a` flag).
  ///   Default: `false`.
  ///
  /// Each returned [ComposeContainer] has its [DockerCompose] back-reference
  /// set so that further operations (logs, inspect) work.
  List<ComposeContainer> containers({bool includeAll = false}) {
    final cmd = [
      ...composeCommandProperty,
      'ps',
      '--format',
      'json',
      if (includeAll) '-a',
    ];
    final result = _runCommand(cmd);
    final output = (result.stdoutString).trim();
    if (output.isEmpty) {
      return [];
    }

    final containers = <ComposeContainer>[];
    for (final line in output.split(RegExp(r'\r?\n'))) {
      if (line.isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is List<dynamic>) {
          containers.addAll(
            decoded.map(
              (e) => ComposeContainer.fromJson(e as Map<String, dynamic>),
            ),
          );
        } else {
          containers.add(
            ComposeContainer.fromJson(decoded as Map<String, dynamic>),
          );
        }
      } on FormatException catch (e) {
        stderr.writeln(
          'testcontainers: ignoring unparseable line from docker compose ps: $e\n  line: $line',
        );
        continue;
      }
    }

    for (final c in containers) {
      c._dockerCompose = this;
    }
    return containers;
  }

  /// Returns a single [ComposeContainer] from the stack.
  ///
  /// Parameters:
  /// - [serviceName] — the Compose service name to look up. When `null`,
  ///   there must be exactly one container running in the stack.
  /// - [includeAll] — include stopped containers in the search.
  ///
  /// Throws [ContainerIsNotRunning] when:
  /// - [serviceName] is `null` and the stack does not have exactly one
  ///   container.
  /// - [serviceName] is given but no matching container is found.
  ComposeContainer container([
    String? serviceName,
    bool includeAll = false,
  ]) {
    if (serviceName == null) {
      final all = containers(includeAll: includeAll);
      return _getOnlyElementOrRaise(
        all,
        () => ContainerIsNotRunning(
          'get_container failed because no service_name given '
          'and there is not exactly 1 container (but ${all.length})',
        ),
      );
    }

    // containers() already sets _dockerCompose on every element — no need to
    // repeat the assignment here.
    final matching = containers(includeAll: includeAll)
        .where((c) => c.service == serviceName)
        .toList();

    if (matching.isEmpty) {
      throw ContainerIsNotRunning(
        '$serviceName is not running in the compose context',
      );
    }

    return matching.first;
  }

  /// Runs [command] inside the named Compose service container.
  ///
  /// Parameters:
  /// - [command] — the command and its arguments.
  /// - [serviceName] — the service to exec into. When `null`, the stack must
  ///   have exactly one running container.
  ///
  /// Returns `(stdout, stderr, exitCode)` — the raw output strings and the
  /// process exit code.
  ///
  /// Throws [ProcessException] when the underlying `docker compose exec` command
  /// fails.
  (String, String, int) execInContainer(
    List<String> command, {
    String? serviceName,
  }) {
    serviceName ??= container().service;
    if (serviceName == null) {
      throw StateError(
        'Cannot exec: could not determine a service name. '
        'Pass serviceName explicitly or ensure the stack has exactly one '
        'running container whose service field is non-null.',
      );
    }
    final cmd = [
      ...composeCommandProperty,
      'exec',
      '-T',
      serviceName,
      ...command,
    ];
    final result = _runCommand(cmd);
    return (
      result.stdoutString,
      result.stderrString,
      result.exitCode,
    );
  }

  /// Returns the host IP address bound to a service's published port.
  ///
  /// Parameters:
  /// - [serviceName] — optional Compose service name; `null` requires exactly
  ///   one running container.
  /// - [port] — optional container port to filter by.
  ///
  /// Returns [PublishedPortModel.url] after normalisation, or `null` when
  /// the publisher has no URL. Throws [NoSuchPortExposed] when filters match
  /// more than one publisher.
  String? serviceHost({String? serviceName, int? port}) {
    final svc = container(serviceName);
    final publisher = svc.publisher(byPort: port).normalize();
    return publisher.url;
  }

  /// Returns the ephemeral host port number for a service's published port.
  ///
  /// Parameters:
  /// - [serviceName] — optional Compose service name; `null` requires exactly
  ///   one running container.
  /// - [port] — optional container port to filter by.
  ///
  /// Returns [PublishedPortModel.publishedPort] after normalisation, or `null`
  /// when the publisher has no published port. Throws [NoSuchPortExposed] when
  /// filters match more than one publisher.
  int? servicePort({String? serviceName, int? port}) {
    final publisher =
        container(serviceName).publisher(byPort: port).normalize();
    return publisher.publishedPort;
  }

  /// Returns both the normalised host address and ephemeral port for a service.
  ///
  /// Equivalent to calling [serviceHost] and [servicePort] together.
  ///
  /// Parameters:
  /// - [serviceName] — optional Compose service name; `null` requires exactly
  ///   one running container.
  /// - [port] — optional container port to filter publishers by.
  ///
  /// Returns `(url, publishedPort)`. Either value may be `null` when the
  /// publisher has no corresponding field. Throws [NoSuchPortExposed] when
  /// filters match more than one publisher.
  (String?, int?) serviceHostAndPort({String? serviceName, int? port}) {
    final publisher =
        container(serviceName).publisher(byPort: port).normalize();
    return (publisher.url, publisher.publishedPort);
  }

  /// Polls [url] until it returns an HTTP 2xx or 3xx response.
  ///
  /// Retries every second for up to [TestcontainersConfiguration.timeout]
  /// seconds. Connection errors and non-2xx/3xx responses are treated as
  /// transient failures.
  ///
  /// Returns `this` for chaining.
  ///
  /// Throws [TimeoutException] when the deadline is exceeded without a
  /// successful response.
  Future<DockerCompose> waitFor(String url) async {
    final timeout = Duration(
      milliseconds: (testcontainersConfig.timeout * 1000).toInt(),
    );
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 1));
        if (response.statusCode >= 200 && response.statusCode < 400) {
          return this;
        }
      } catch (_) {
        // connection refused / timeout — keep trying
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw TimeoutException('URL $url not ready within $timeout');
  }

  /// Runs [cmd] as a synchronous subprocess in [context].
  ///
  /// Throws [ProcessException] when the command exits with a non-zero status.
  ProcessResult _runCommand(
    List<String> cmd, {
    String? workingDirectory,
  }) {
    final cwd = workingDirectory ?? context;
    final result = Process.runSync(
      cmd.first,
      cmd.sublist(1),
      workingDirectory: cwd,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        cmd.first,
        cmd.sublist(1),
        result.stderrString,
        result.exitCode,
      );
    }
    return result;
  }

  /// Brings up [compose], runs [fn] with it, and tears it down afterwards.
  ///
  /// Teardown uses `docker compose down --volumes` when [DockerCompose.keepVolumes]
  /// is `false`, or `docker compose stop` when it is `true`. The stack is torn
  /// down even if [fn] throws.
  ///
  /// Example:
  /// ```dart
  /// await DockerCompose.use(
  ///   DockerCompose(context: 'test/fixtures'),
  ///   (compose) async {
  ///     // run tests against the live stack
  ///   },
  /// );
  /// ```
  static Future<T> use<T>(
    DockerCompose compose,
    Future<T> Function(DockerCompose) fn,
  ) async {
    await compose.start();
    try {
      return await fn(compose);
    } finally {
      compose.stop(down: !compose.keepVolumes);
    }
  }
}
