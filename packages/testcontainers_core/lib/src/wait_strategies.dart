/// Concrete wait strategies for determining when a container is ready.
///
/// All strategies extend [WaitStrategy] and implement [WaitStrategy.waitUntilReady].
/// They are attached to a [DockerContainer] via `waitingFor(strategy)` and
/// invoked automatically by [DockerContainer.start].
///
/// The statuses considered "still starting" (i.e. neither ready nor failed)
/// are defined by [notExitedStatuses].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'waiting_utils.dart';

/// Container statuses that indicate the container is still alive and worth
/// continuing to poll.
///
/// If [WaitStrategyTarget.status] is NOT in this set and a wait strategy has
/// not yet succeeded, the strategy raises a [StateError] instead of waiting
/// for the timeout.
const Set<String> notExitedStatuses = {'running', 'created'};

/// Convenience function that waits for container log output to match a pattern.
///
/// Creates a [LogMessageWaitStrategy] internally and invokes it immediately.
/// Returns the elapsed wait time as a [Duration].
///
/// Parameters:
/// - [container] — the container to watch.
/// - [predicate] — a [String] (compiled to `RegExp`), [RegExp], or any
///   [Pattern] to search for.
/// - [timeout] — optional startup-timeout override. Defaults to
///   [TestcontainersConfiguration.timeout] (120 seconds).
/// - [interval] — poll interval. Default: 1 second.
/// - [predicateStreamsAnd] — when `true`, [predicate] must match **both**
///   stdout and stderr. When `false` (default) matching either stream
///   is sufficient.
///
/// Example:
/// ```dart
/// await waitForLogs(container, 'Server started on port');
/// ```
Future<Duration> waitForLogs(
  WaitStrategyTarget container,
  Pattern predicate, {
  Duration? timeout,
  Duration interval = const Duration(seconds: 1),
  bool predicateStreamsAnd = false,
}) async {
  final effectiveTimeout = timeout ??
      Duration(milliseconds: (testcontainersConfig.timeout * 1000).toInt());
  final strategy = LogMessageWaitStrategy(
    predicate,
    predicateStreamsAnd: predicateStreamsAnd,
  )
    ..withStartupTimeout(effectiveTimeout)
    ..withPollInterval(interval);
  final start = DateTime.now();
  await strategy.waitUntilReady(container);
  return DateTime.now().difference(start);
}

/// Waits until a specific log message appears in the container's output.
///
/// Polls [WaitStrategyTarget.logs] repeatedly. Each iteration also calls
/// [WaitStrategyTarget.reload] so that the container status is up-to-date.
///
/// Example:
/// ```dart
/// container.waitingFor(
///   LogMessageWaitStrategy(RegExp(r'Started\.'))
///     ..withStartupTimeout(const Duration(seconds: 60)),
/// );
/// ```
class LogMessageWaitStrategy extends WaitStrategy {
  /// The pattern to search for in the container's log output.
  ///
  /// A [String] is compiled to a multi-line [RegExp]. A [RegExp] is used
  /// as-is. Any other [Pattern] is converted via [Object.toString] and
  /// compiled.
  final Pattern message;

  /// The minimum number of times [message] must appear before the container
  /// is considered ready.
  ///
  /// Defaults to `1`.
  final int times;

  /// Whether [message] must appear in **both** stdout and stderr.
  ///
  /// When `false` (default), matching either stream is sufficient (logical OR).
  final bool predicateStreamsAnd;

  /// Creates a [LogMessageWaitStrategy] that waits for [message] to appear
  /// at least [times] times in the container logs.
  LogMessageWaitStrategy(
    this.message, {
    this.times = 1,
    this.predicateStreamsAnd = false,
  });

  /// Polls the container's log output until [message] appears [times] times.
  ///
  /// Throws [TimeoutException] when [startupTimeout] elapses without a match.
  /// Throws [StateError] when the container exits before the pattern is found.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final pattern = switch (message) {
      final RegExp r => r,
      _ => RegExp(message.toString(), multiLine: true),
    };

    final ready = await poll(() async {
      await target.reload();
      final (stdout, stderr) = await target.logs();
      final stdoutStr = utf8.decode(stdout, allowMalformed: true);
      final stderrStr = utf8.decode(stderr, allowMalformed: true);

      bool check(String text) {
        final matches = pattern.allMatches(text);
        return matches.length >= times;
      }

      if (predicateStreamsAnd) {
        return check(stdoutStr) && check(stderrStr);
      }
      return check(stdoutStr) || check(stderrStr);
    });

    if (!ready) {
      if (!notExitedStatuses.contains(target.status)) {
        throw StateError(
          'Container exited before log message found. Status: ${target.status}',
        );
      }
      throw TimeoutException(
        'Log message not found within $startupTimeout. '
        'Container status: ${target.status}',
      );
    }
  }
}

/// Waits until an HTTP endpoint inside the container returns an acceptable
/// response.
///
/// On each poll attempt the strategy sends an HTTP request to the container
/// and checks:
/// 1. The response status code (against [forStatusCode] or
///    [forStatusCodeMatching]).
/// 2. Optionally, the response body (via [forResponsePredicate]).
///
/// Each individual request times out after 1 second. [SocketException],
/// [TimeoutException], and [http.ClientException] are treated as transient
/// failures.
///
/// Example:
/// ```dart
/// container.waitingFor(
///   HttpWaitStrategy(8080, path: '/health')
///     .forStatusCode(200)
///     ..withStartupTimeout(const Duration(seconds: 60)),
/// );
/// ```
class HttpWaitStrategy extends WaitStrategy {
  /// The container port to probe.
  final int port;

  /// The URL path to request. Always starts with `/`.
  final String path;

  final Set<int> _statusCodes = {200};
  bool Function(int)? _statusCodeMatcher;
  bool Function(String)? _responsePredicate;
  bool _tls = false;
  bool _insecureTls = false;
  final Map<String, String> _headers = {};
  String _method = 'GET';
  String? _body;

  /// Creates an [HttpWaitStrategy] that probes [port] at [path].
  ///
  /// [path] defaults to `'/'` and is normalised to start with `/`.
  HttpWaitStrategy(this.port, {String path = '/'})
      : path = path.startsWith('/') ? path : '/$path';

  /// Creates an [HttpWaitStrategy] from a full URL string.
  ///
  /// The port, path, and TLS flag are extracted automatically from [url].
  /// When the scheme is `https`, [usingTls] is called implicitly.
  ///
  /// Example:
  /// ```dart
  /// HttpWaitStrategy.fromUrl('https://localhost:8443/api/health')
  /// ```
  factory HttpWaitStrategy.fromUrl(String url) {
    final parsed = Uri.parse(url);
    final effectivePort =
        parsed.hasPort ? parsed.port : (parsed.scheme == 'https' ? 443 : 80);
    final effectivePath = parsed.path.isEmpty ? '/' : parsed.path;
    final strategy = HttpWaitStrategy(effectivePort, path: effectivePath);
    if (parsed.scheme == 'https') {
      strategy.usingTls();
    }
    return strategy;
  }

  /// Adds [code] to the set of acceptable HTTP status codes.
  ///
  /// By default only `200` is accepted. Call this method multiple times to
  /// accept a range of codes. Ignored when [forStatusCodeMatching] is set.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy forStatusCode(int code) {
    _statusCodes.add(code);
    return this;
  }

  /// Replaces the status-code check with a custom [matcher] function.
  ///
  /// When set, [matcher] takes precedence over any codes added via
  /// [forStatusCode].
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy forStatusCodeMatching(bool Function(int) matcher) {
    _statusCodeMatcher = matcher;
    return this;
  }

  /// Adds an additional response body check on top of the status-code check.
  ///
  /// The response body is decoded as a UTF-8 string and passed to [predicate].
  /// Both the status-code check and [predicate] must pass for the container to
  /// be considered ready.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy forResponsePredicate(bool Function(String) predicate) {
    _responsePredicate = predicate;
    return this;
  }

  /// Switches the request scheme to `https`.
  ///
  /// When [insecure] is `true`, certificate validation is disabled — useful
  /// for containers with self-signed certificates.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy usingTls({bool insecure = false}) {
    _tls = true;
    _insecureTls = insecure;
    return this;
  }

  /// Adds a custom HTTP request header.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy withHeader(String name, String value) {
    _headers[name] = value;
    return this;
  }

  /// Sets HTTP Basic authentication credentials.
  ///
  /// The credentials are base64-encoded as `username:password` and added
  /// as an `Authorization: Basic <encoded>` header.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy withBasicCredentials(String username, String password) {
    final encoded = base64.encode(utf8.encode('$username:$password'));
    _headers['Authorization'] = 'Basic $encoded';
    return this;
  }

  /// Sets the HTTP method used for each probe request.
  ///
  /// Defaults to `'GET'`. The value is upper-cased automatically.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy withMethod(String method) {
    _method = method.toUpperCase();
    return this;
  }

  /// Sets a request body to include with each probe request.
  ///
  /// Returns `this` for chaining.
  HttpWaitStrategy withBody(String body) {
    _body = body;
    return this;
  }

  /// The current set of HTTP headers that will be sent with each probe request.
  ///
  /// Exposed for unit testing only — do not read from production code.
  @visibleForTesting
  Map<String, String> get testHeaders => Map.unmodifiable(_headers);

  /// The HTTP method that will be used for each probe request.
  ///
  /// Exposed for unit testing only — do not read from production code.
  @visibleForTesting
  String get testMethod => _method;

  /// The set of HTTP status codes that are considered successful.
  ///
  /// Exposed for unit testing only — do not read from production code.
  @visibleForTesting
  Set<int> get testStatusCodes => Set.unmodifiable(_statusCodes);

  /// Polls the HTTP endpoint until an acceptable response is received.
  ///
  /// The URL is `{http|https}://{host}:{mappedPort}{path}`. Throws
  /// [TimeoutException] when [startupTimeout] elapses without success.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final host = await target.containerHostIp();
    final mappedPort = await target.exposedPort(port);
    final scheme = _tls ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$mappedPort$path');

    // Created once and reused across all poll attempts. Must be closed
    // after polling regardless of outcome to avoid a connection leak.
    HttpClient? insecureClient;
    if (_insecureTls) {
      insecureClient = HttpClient()
        ..badCertificateCallback = (_, __, ___) => true;
    }

    final bool ready;
    try {
      ready = await poll(
        () async {
          try {
            http.Response response;
            if (insecureClient != null) {
              final req = await insecureClient.openUrl(_method, uri);
              for (final entry in _headers.entries) {
                req.headers.set(entry.key, entry.value);
              }
              if (_body != null) {
                req.write(_body);
              }
              final ioResp = await req.close().timeout(
                    const Duration(seconds: 1),
                  );
              final bodyBytes = await ioResp.fold<List<int>>(
                [],
                (prev, elem) => prev..addAll(elem),
              );
              response = http.Response.bytes(
                Uint8List.fromList(bodyBytes),
                ioResp.statusCode,
              );
            } else {
              final client = http.Client();
              try {
                final request = http.Request(_method, uri);
                request.headers.addAll(_headers);
                final body = _body;
                if (body != null) {
                  request.body = body;
                }
                final streamed = await client
                    .send(request)
                    .timeout(const Duration(seconds: 1));
                response = await http.Response.fromStream(streamed);
              } finally {
                client.close();
              }
            }

            final statusOk = _statusCodeMatcher != null
                ? _statusCodeMatcher!(response.statusCode)
                : _statusCodes.contains(response.statusCode);

            if (!statusOk) {
              return false;
            }
            if (_responsePredicate != null) {
              return _responsePredicate!(response.body);
            }
            return true;
          } on TimeoutException {
            return false;
          } on SocketException {
            return false;
          } on http.ClientException {
            return false;
          }
        },
        transientExceptions: [SocketException, TimeoutException],
      );
    } finally {
      // Release the insecure HttpClient regardless of poll outcome or any
      // unexpected exception thrown by a non-transient error in the loop.
      insecureClient?.close(force: true);
    }

    if (!ready) {
      throw TimeoutException(
        'HTTP endpoint not ready within $startupTimeout',
      );
    }
  }
}

/// Waits until a container's Docker health check reports `'healthy'`.
///
/// Polls the container's inspect data (`State.Health.Status`) via
/// [WaitStrategyTarget.wrappedContainer]. Requires the container's image
/// to have a `HEALTHCHECK` instruction or a health check injected at runtime.
///
/// Behaviour:
/// - `'healthy'` → ready.
/// - `'starting'` → keeps polling.
/// - `'unhealthy'` → throws [StateError] immediately with log output.
/// - `null` or empty → throws [StateError] (no health check configured).
///
/// Example:
/// ```dart
/// container.waitingFor(HealthcheckWaitStrategy());
/// ```
class HealthcheckWaitStrategy extends WaitStrategy {
  /// Polls the container's built-in health-check status until `'healthy'`.
  ///
  /// Throws [StateError] immediately when the status becomes `'unhealthy'` or
  /// when no health check is configured on the image. Throws [TimeoutException]
  /// when [startupTimeout] elapses before `'healthy'` is reached.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final ready = await poll(() async {
      await target.reload();

      String? healthStatus;
      try {
        final info = await target.containerInfo();
        healthStatus = info?.state?.health?.status;
      } catch (e) {
        stderr.writeln('testcontainers: error fetching health status: $e');
        healthStatus = null;
      }

      if (healthStatus == null || healthStatus.isEmpty) {
        throw StateError(
          'Container has no health check configured: $target',
        );
      }
      if (healthStatus == 'healthy') {
        return true;
      }
      if (healthStatus == 'unhealthy') {
        final (stdout, stderrBytes) = await target.logs();
        final logs = utf8.decode(
          Uint8List.fromList([...stdout, ...stderrBytes]),
          allowMalformed: true,
        );
        throw StateError('Container is unhealthy. Logs: $logs');
      }
      return false; // 'starting' — keep waiting
    });

    if (!ready) {
      throw TimeoutException(
        'Container not healthy within $startupTimeout',
      );
    }
  }
}

/// Waits until a TCP connection to the specified [port] can be established.
///
/// Attempts a [Socket.connect] to the container's mapped host port with a
/// 1-second timeout per attempt. [SocketException] and [TimeoutException]
/// are treated as transient failures.
///
/// Example:
/// ```dart
/// container
///   ..withExposedPorts([5432])
///   ..waitingFor(PortWaitStrategy(5432));
/// ```
class PortWaitStrategy extends WaitStrategy {
  /// The container port to probe for TCP connectivity.
  final int port;

  /// Creates a [PortWaitStrategy] that probes [port].
  PortWaitStrategy(this.port);

  /// Attempts a TCP connection to [port] on each poll cycle.
  ///
  /// Throws [TimeoutException] when [startupTimeout] elapses without a
  /// successful TCP connection.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final host = await target.containerHostIp();

    final ready = await poll(
      () async {
        try {
          final socket = await Socket.connect(
            host,
            await target.exposedPort(port),
          ).timeout(const Duration(seconds: 1));
          await socket.close();
          return true;
        } on SocketException {
          return false;
        } on TimeoutException {
          return false;
        }
      },
      transientExceptions: [SocketException, TimeoutException],
    );

    if (!ready) {
      throw TimeoutException(
        'Port $port not available within $startupTimeout',
      );
    }
  }
}

/// Waits until a specific file exists on the container's filesystem.
///
/// Runs `test -f <filePath>` inside the container on each poll attempt via
/// `exec`. A zero exit code means the file exists. On timeout, a
/// diagnostic `ls` of the parent directory is run inside the container to
/// help identify why the file was not created.
///
/// Example:
/// ```dart
/// container.waitingFor(FileExistsWaitStrategy('/tmp/ready'));
/// ```
class FileExistsWaitStrategy extends WaitStrategy {
  /// The absolute path inside the container to check for existence.
  final String filePath;

  /// Creates a [FileExistsWaitStrategy] that waits for [filePath] to appear.
  FileExistsWaitStrategy(this.filePath);

  /// Runs `test -f <filePath>` inside the container on each poll cycle.
  ///
  /// On timeout, a diagnostic `ls` of the parent directory is run inside the
  /// container and included in the [TimeoutException] message.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final ready = await poll(() async {
      final (exitCode, _) = await target.exec(['test', '-f', filePath]);
      return exitCode == 0;
    });

    if (!ready) {
      // Best-effort: list the parent directory inside the container for diagnostics.
      String listing = '(unavailable)';
      try {
        // p.dirname handles edge cases such as '/ready' → '/' correctly.
        final parent = p.dirname(filePath);
        final (_, output) = await target.exec(['ls', '-la', parent]);
        listing = String.fromCharCodes(output);
      } catch (_) {
        // Diagnostic only — ignore errors.
      }
      throw TimeoutException(
        'File $filePath not found in container within $startupTimeout. '
        'Parent directory contents: $listing',
      );
    }
  }
}

/// Waits until the container's lifecycle status is `'running'`.
///
/// If the status moves into any state not listed in [continueStatuses], the
/// strategy stops polling immediately and throws a [StateError] (rather than
/// waiting for the full timeout), because the container has terminated and
/// will not become `'running'`.
///
/// This strategy is used internally by [DockerContainer.exposedPort] to
/// ensure the container is started before port mapping is queried.
///
/// Example:
/// ```dart
/// container.waitingFor(ContainerStatusWaitStrategy());
/// ```
class ContainerStatusWaitStrategy extends WaitStrategy {
  /// Status values that mean "still starting, keep polling".
  ///
  /// If the container reaches any status not in this set (and not
  /// `'running'`), polling stops immediately.
  static const Set<String> continueStatuses = {'created', 'restarting'};

  /// Polls the container status until it equals `'running'`.
  ///
  /// Stops polling immediately (without waiting for the full timeout) when the
  /// status is not in [continueStatuses]. Throws [StateError] if readiness is
  /// never reached.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final ready = await poll(() async {
      await target.reload();
      final st = target.status;
      if (st == 'running') {
        return true;
      }
      if (!continueStatuses.contains(st)) {
        throwStopIteration();
      }
      return false;
    });

    if (!ready) {
      throw StateError('Container not running. Status: ${target.status}');
    }
  }
}

/// Chains multiple wait strategies and runs them in sequence.
///
/// All child strategies are applied in order; the container is considered
/// ready only after **every** strategy succeeds.
///
/// [withStartupTimeout] and [withPollInterval] are propagated to all child
/// strategies so that a single call configures the entire chain.
///
/// Example:
/// ```dart
/// container.waitingFor(
///   CompositeWaitStrategy([
///     PortWaitStrategy(8080),
///     HttpWaitStrategy(8080, path: '/ready'),
///   ]),
/// );
/// ```
class CompositeWaitStrategy extends WaitStrategy {
  /// The ordered list of strategies to run.
  final List<WaitStrategy> strategies;

  /// Creates a [CompositeWaitStrategy] from a list of child [strategies].
  CompositeWaitStrategy(List<WaitStrategy> strategies)
      : strategies = List.unmodifiable(strategies);

  /// Sets [startupTimeout] on this strategy and on all child [strategies].
  ///
  /// Returns `this`.
  @override
  WaitStrategy withStartupTimeout(Duration timeout) {
    super.withStartupTimeout(timeout);
    for (final s in strategies) {
      s.withStartupTimeout(timeout);
    }
    return this;
  }

  /// Sets [pollInterval] on this strategy and on all child [strategies].
  ///
  /// Returns `this`.
  @override
  WaitStrategy withPollInterval(Duration interval) {
    super.withPollInterval(interval);
    for (final s in strategies) {
      s.withPollInterval(interval);
    }
    return this;
  }

  /// Appends [exceptions] to the transient list on this strategy and on all
  /// child [strategies]. Returns `this`.
  @override
  WaitStrategy withTransientExceptions(List<Type> exceptions) {
    super.withTransientExceptions(exceptions);
    for (final s in strategies) {
      s.withTransientExceptions(exceptions);
    }
    return this;
  }

  /// Runs all [strategies] in sequence against [target].
  ///
  /// Each strategy is awaited in order; the first to throw propagates the
  /// exception and remaining strategies are skipped.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    for (final strategy in strategies) {
      await strategy.waitUntilReady(target);
    }
  }
}

/// Waits until a command executed inside the container exits with the expected
/// exit code.
///
/// The command is run by calling [WaitStrategyTarget.exec] on each poll
/// cycle.
///
/// Example:
/// ```dart
/// container.waitingFor(
///   ExecWaitStrategy(['pg_isready', '-U', 'postgres']),
/// );
/// ```
class ExecWaitStrategy extends WaitStrategy {
  /// The command to run inside the container on each poll attempt.
  final List<String> command;

  /// The exit code that indicates the container is ready.
  ///
  /// Defaults to `0` (success).
  final int expectedExitCode;

  /// Creates an [ExecWaitStrategy] for [command].
  ///
  /// [command] is the command and its arguments. [expectedExitCode] defaults
  /// to `0`.
  ExecWaitStrategy(List<String> command, {this.expectedExitCode = 0})
      : command = List.unmodifiable(command);

  /// Creates an [ExecWaitStrategy] that runs a single shell command string.
  ///
  /// Equivalent to `ExecWaitStrategy([command])`.
  factory ExecWaitStrategy.shell(String command, {int expectedExitCode = 0}) =>
      ExecWaitStrategy([command], expectedExitCode: expectedExitCode);

  /// Runs [command] inside the container on each poll cycle until its exit code
  /// equals [expectedExitCode].
  ///
  /// Throws [TimeoutException] when [startupTimeout] elapses without the
  /// expected exit code being returned.
  @override
  Future<void> waitUntilReady(WaitStrategyTarget target) async {
    final ready = await poll(() async {
      final (exitCode, _) = await target.exec(command);
      return exitCode == expectedExitCode;
    });

    if (!ready) {
      throw TimeoutException(
        'Exec command $command did not return $expectedExitCode '
        'within $startupTimeout',
      );
    }
  }
}
