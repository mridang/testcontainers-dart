/// Core wait-strategy infrastructure.
///
/// [WaitStrategyTarget] is the interface that both [DockerContainer] and
/// `ComposeContainer` implement to expose the container state that wait
/// strategies need to poll.
///
/// [WaitStrategy] is the abstract base class for all concrete strategies in
/// `wait_strategies.dart`. It owns the adaptive polling loop ([poll]) and
/// exposes fluent builder methods for configuring the timeout and poll
/// interval.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'inspect.dart';

/// The interface that must be implemented by any object that can be passed to
/// [WaitStrategy.waitUntilReady].
///
/// Both [DockerContainer] and `ComposeContainer` implement this interface,
/// allowing the same wait strategies to be used with standalone containers and
/// Docker Compose services.
abstract interface class WaitStrategyTarget {
  /// Returns the host IP address through which the container is reachable.
  ///
  /// The returned address depends on the active [ConnectionMode]:
  /// - `dockerHost` → the Docker daemon's host address
  /// - `gatewayIp` → the bridge network's gateway IP
  /// - `bridgeIp` → the container's own bridge IP
  Future<String> containerHostIp();

  /// Returns the host-side port that is mapped to the container's [port].
  ///
  /// For connection modes that use mapped ports, this queries the Docker
  /// daemon for the ephemeral port assigned by the host OS. For `bridgeIp`
  /// mode, [port] is returned unchanged.
  Future<int> exposedPort(int port);

  /// The underlying container object.
  ///
  /// For [DockerContainer] this is `this`. For `ComposeContainer` this is
  /// also `this`. Prefer calling typed methods on [WaitStrategyTarget]
  /// directly instead of casting this value.
  Object get wrappedContainer;

  /// Fetches the container's current stdout and stderr log output.
  ///
  /// Returns a record `(stdout, stderr)` of raw bytes. The caller is
  /// responsible for decoding (typically UTF-8 with `allowMalformed: true`).
  Future<(Uint8List stdout, Uint8List stderr)> logs();

  /// Runs [command] inside the container and returns its exit code and output.
  ///
  /// Returns `(exitCode, combinedOutputBytes)`. Implementations may combine
  /// stdout and stderr into a single byte buffer.
  ///
  /// Throws [StateError] when called before the container is started, or when
  /// the target does not have an `exec` capability.
  Future<(int, Uint8List)> exec(List<String> command);

  /// Returns the full Docker inspect information for this container.
  ///
  /// The result is lazily loaded and cached by most implementations. Returns
  /// `null` when the container has not yet been started or when the inspect
  /// call fails.
  Future<ContainerInspectInfo?> containerInfo();

  /// Refreshes the cached container state from the Docker daemon.
  ///
  /// Called by polling strategies between attempts to pick up status changes.
  Future<void> reload();

  /// The most recently cached container lifecycle state string.
  ///
  /// Typical values: `'running'`, `'created'`, `'exited'`, `'paused'`,
  /// `'restarting'`, `'dead'`, `'not_started'`, `'unknown'`.
  String get status;
}

/// Abstract base class for all wait strategies.
///
/// Provides:
/// - Fluent builder methods ([withStartupTimeout], [withPollInterval],
///   [withTransientExceptions]) that return `this` for chaining.
/// - An adaptive [poll] loop that calls a supplied check function at most
///   once per [pollInterval] second, retrying until the deadline or until
///   the check returns `true`.
///
/// Concrete subclasses must implement [waitUntilReady].
///
/// Example:
/// ```dart
/// final strategy = PortWaitStrategy(8080)
///   ..withStartupTimeout(const Duration(seconds: 30))
///   ..withPollInterval(const Duration(milliseconds: 500));
/// await strategy.waitUntilReady(container);
/// ```
abstract class WaitStrategy {
  /// Maximum time to wait for the container to become ready.
  ///
  /// Defaults to [TestcontainersConfiguration.timeout] (`maxTries × sleepTime`,
  /// which is 120 seconds unless overridden by environment variables).
  Duration startupTimeout = Duration(
    milliseconds: (testcontainersConfig.timeout * 1000).toInt(),
  );

  /// Time between successive polling attempts.
  ///
  /// Defaults to [TestcontainersConfiguration.sleepTime] (1 second).
  Duration pollInterval = Duration(
    milliseconds: (testcontainersConfig.sleepTime * 1000).toInt(),
  );

  Set<Type> _transientExceptions = const {TimeoutException, SocketException};

  /// Sets the maximum startup timeout.
  ///
  /// Returns `this` to allow fluent chaining.
  WaitStrategy withStartupTimeout(Duration timeout) {
    startupTimeout = timeout;
    return this;
  }

  /// Sets the poll interval between readiness checks.
  ///
  /// Returns `this` to allow fluent chaining.
  WaitStrategy withPollInterval(Duration interval) {
    pollInterval = interval;
    return this;
  }

  /// Adds [exceptions] to the set of exception types that are treated as
  /// transient failures during polling.
  ///
  /// A transient exception causes the current poll attempt to be silently
  /// retried. Any exception type not in the transient set will be re-thrown
  /// immediately, halting the wait.
  ///
  /// [TimeoutException] and [SocketException] are always transient regardless
  /// of what is passed here. Duplicate types are silently ignored.
  ///
  /// Returns `this` to allow fluent chaining.
  WaitStrategy withTransientExceptions(List<Type> exceptions) {
    _transientExceptions = {..._transientExceptions, ...exceptions};
    return this;
  }

  /// Waits until the container described by [target] is ready.
  ///
  /// Must be implemented by every concrete strategy. Implementations should
  /// call [poll] to perform the actual waiting loop, then throw an appropriate
  /// exception if readiness was not achieved:
  /// - [TimeoutException] — the [startupTimeout] elapsed before the condition
  ///   was met.
  /// - [StateError] — the container entered a terminal state from which it
  ///   cannot recover (e.g. `'unhealthy'`, `'exited'`), making further polling
  ///   pointless.
  Future<void> waitUntilReady(WaitStrategyTarget target);

  /// Adaptive polling loop.
  ///
  /// Repeatedly calls [check] until it returns `true`, the [startupTimeout]
  /// elapses, or [check] throws a non-transient exception.
  ///
  /// Behaviour:
  /// - Each iteration measures how long [check] itself took and sleeps only
  ///   for the remainder of [pollInterval] (adaptive sleep to maintain
  ///   per-interval cadence without busy-waiting).
  /// - [TimeoutException] and [SocketException] are always treated as
  ///   transient. Additional types can be added via [transientExceptions].
  /// - A `_StopIteration` thrown inside [check] causes polling to stop
  ///   immediately and returns `false` (used by
  ///   [ContainerStatusWaitStrategy]).
  /// - Returns `true` as soon as [check] returns `true`.
  /// - Returns `false` after the deadline is exceeded without success.
  ///
  /// Parameters:
  /// - [check] — async predicate that returns `true` when the container is
  ///   ready.
  /// - [transientExceptions] — additional exception types to swallow during
  ///   polling for this specific call.
  Future<bool> poll(
    Future<bool> Function() check, {
    List<Type>? transientExceptions,
  }) async {
    final allTransient = <Type>{
      ..._transientExceptions,
      ...?transientExceptions,
    };
    final deadline = DateTime.now().add(startupTimeout);

    while (DateTime.now().isBefore(deadline)) {
      final checkStart = DateTime.now();
      try {
        if (await check()) {
          return true;
        }
      } on _StopIteration {
        return false;
      } catch (e) {
        final isTransient = allTransient.any((t) => _isTransient(e, t));
        if (!isTransient) {
          rethrow;
        }
      }
      final elapsed = DateTime.now().difference(checkStart);
      final remaining = pollInterval - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    return false;
  }

  /// Returns `true` when [e] matches the transient exception [type].
  ///
  /// Uses `is` checks for built-in transient types ([TimeoutException] and
  /// [SocketException]) so that subclasses are correctly matched. Falls back
  /// to an exact `runtimeType ==` comparison for user-supplied types registered
  /// via [withTransientExceptions].
  static bool _isTransient(Object e, Type type) {
    if (type == TimeoutException) {
      return e is TimeoutException;
    }
    if (type == SocketException) {
      return e is SocketException;
    }
    return e.runtimeType == type;
  }
}

/// Internal sentinel exception used to break out of the [WaitStrategy.poll]
/// loop early when the container has moved into a terminal state.
///
/// Throw via [throwStopIteration] inside a [WaitStrategy.poll] check callback.
class _StopIteration implements Exception {}

/// Throws [_StopIteration] to signal that the poll loop should stop
/// immediately without waiting for the timeout.
///
/// Used by [ContainerStatusWaitStrategy] when the container enters an
/// unexpected state (e.g. `'exited'` or `'dead'`) from which it cannot
/// recover.
void throwStopIteration() => throw _StopIteration();
