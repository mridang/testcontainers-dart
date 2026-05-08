@Tags(['unit'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:testcontainers/src/inspect.dart';
import 'package:testcontainers/src/wait_strategies.dart';
import 'package:testcontainers/src/waiting_utils.dart';

class MockWaitStrategyTarget extends Mock implements WaitStrategyTarget {}

// ---------------------------------------------------------------------------
// Exception subclasses used to test _isTransient dispatch rules.
//
// _isTransient uses `is` for built-in types (TimeoutException, SocketException)
// so their subclasses are caught as transient. For user-registered types it
// falls back to `runtimeType ==` so only the exact type is caught.
// ---------------------------------------------------------------------------

/// A subclass of [SocketException] used to verify that the `is` path in
/// [WaitStrategy._isTransient] catches subclasses of [SocketException].
class _SubSocketException extends SocketException {
  _SubSocketException() : super('subclass socket error');
}

/// A subclass of [TimeoutException] used to verify that the `is` path in
/// [WaitStrategy._isTransient] catches subclasses of [TimeoutException].
class _SubTimeoutException extends TimeoutException {
  _SubTimeoutException() : super('subclass timeout');
}

/// A subclass of [FormatException] used to verify that the `runtimeType ==`
/// path in [WaitStrategy._isTransient] does NOT catch subclasses of
/// user-registered transient exception types.
class _SubFormatException extends FormatException {
  const _SubFormatException() : super('subclass format error');
}

void main() {
  late MockWaitStrategyTarget target;

  setUp(() {
    target = MockWaitStrategyTarget();
    when(() => target.reload()).thenAnswer((_) async {});
    when(() => target.status).thenReturn('running');
    when(() => target.containerHostIp()).thenAnswer(
      (_) async => '127.0.0.1',
    );
    when(() => target.exposedPort(any())).thenAnswer(
      (inv) async => inv.positionalArguments.first as int,
    );
    when(() => target.wrappedContainer).thenReturn(Object());
    when(() => target.logs()).thenAnswer(
      (_) async => (Uint8List(0), Uint8List(0)),
    );
    when(() => target.exec(any())).thenAnswer(
      (_) async => (0, Uint8List(0)),
    );
    when(() => target.containerInfo()).thenAnswer((_) async => null);
  });

  group('LogMessageWaitStrategy', () {
    test('succeeds when log contains message', () async {
      final stdout =
          Uint8List.fromList('Server started successfully'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (stdout, Uint8List(0)),
      );

      final strategy = LogMessageWaitStrategy('Server started')
        ..withStartupTimeout(const Duration(seconds: 5));

      await expectLater(
        strategy.waitUntilReady(target),
        completes,
      );
    });

    test('throws TimeoutException when message never appears', () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), Uint8List(0)),
      );

      final strategy = LogMessageWaitStrategy('never-gonna-appear')
        ..withStartupTimeout(const Duration(milliseconds: 100));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<Exception>()),
      );
    });

    test('TimeoutException message contains the container status', () async {
      // The message includes "Container status: <status>" for debugging.
      when(() => target.status).thenReturn('running');
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), Uint8List(0)),
      );
      final strategy = LogMessageWaitStrategy('never-appears')
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('running'),
          ),
        ),
      );
    });

    test('accepts RegExp as pattern', () async {
      final stdout = Uint8List.fromList('App ready on port 8080'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (stdout, Uint8List(0)),
      );

      final strategy = LogMessageWaitStrategy(RegExp(r'ready on port \d+'))
        ..withStartupTimeout(const Duration(seconds: 5));

      await expectLater(
        strategy.waitUntilReady(target),
        completes,
      );
    });

    test('checks stderr when stdout empty', () async {
      final stderr = Uint8List.fromList('Ready!'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), stderr),
      );

      final strategy = LogMessageWaitStrategy('Ready!')
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test(
        'throws StateError (not TimeoutException) when container exits '
        'before log message found', () async {
      // status 'exited' is not in notExitedStatuses → once poll times out,
      // LogMessageWaitStrategy raises StateError, not TimeoutException.
      when(() => target.status).thenReturn('exited');
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), Uint8List(0)),
      );

      final strategy = LogMessageWaitStrategy('never-appears')
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exited'),
          ),
        ),
      );
    });
  });

  group('ContainerStatusWaitStrategy', () {
    test('succeeds when status is running', () async {
      when(() => target.status).thenReturn('running');
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('continueStatuses contains created and restarting', () {
      expect(
        ContainerStatusWaitStrategy.continueStatuses,
        containsAll(['created', 'restarting']),
      );
    });

    test('throws StateError immediately on terminal status (exited)', () async {
      // status = 'exited' is not in continueStatuses, so polling must stop
      // right away via throwStopIteration() and raise StateError, not timeout.
      when(() => target.status).thenReturn('exited');
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        // Give a generous timeout — the test must not rely on it expiring.
        ..withStartupTimeout(const Duration(seconds: 30));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<StateError>()),
      );
    });

    test('throws StateError immediately on dead status', () async {
      when(() => target.status).thenReturn('dead');
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 30));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<StateError>()),
      );
    });

    test('StateError message contains the container status', () async {
      // The StateError is thrown with "Container not running. Status: <status>".
      when(() => target.status).thenReturn('exited');
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 30));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('not running'),
              contains('exited'),
            ),
          ),
        ),
      );
    });

    test('throws StateError immediately on paused status', () async {
      // 'paused' is not in continueStatuses ({'created','restarting'}) and is
      // not 'running' → throwStopIteration() fires immediately.
      when(() => target.status).thenReturn('paused');
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 30));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<StateError>()),
      );
    });

    test('keeps polling when status is "created" then transitions to "running"',
        () async {
      // 'created' is in continueStatuses — poll continues; 'running' succeeds.
      var callCount = 0;
      when(() => target.status).thenAnswer((_) {
        callCount++;
        return callCount < 3 ? 'created' : 'running';
      });
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5))
        ..withPollInterval(const Duration(milliseconds: 10));

      await expectLater(strategy.waitUntilReady(target), completes);
      expect(callCount, greaterThanOrEqualTo(3));
    });

    test(
        'keeps polling when status is "restarting" then transitions to "running"',
        () async {
      // 'restarting' is also in continueStatuses — poll continues until running.
      var callCount = 0;
      when(() => target.status).thenAnswer((_) {
        callCount++;
        return callCount < 3 ? 'restarting' : 'running';
      });
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5))
        ..withPollInterval(const Duration(milliseconds: 10));

      await expectLater(strategy.waitUntilReady(target), completes);
      expect(callCount, greaterThanOrEqualTo(3));
    });

    test('throws StateError immediately when status is "not_started"',
        () async {
      // 'not_started' is NOT in continueStatuses and is not 'running' →
      // throwStopIteration() fires immediately; StateError, not TimeoutException.
      when(() => target.status).thenReturn('not_started');
      when(() => target.reload()).thenAnswer((_) async {});

      final strategy = ContainerStatusWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 30));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<StateError>()),
      );
    });

    test('continueStatuses has exactly two entries', () {
      expect(ContainerStatusWaitStrategy.continueStatuses.length, equals(2));
    });
  });

  group('notExitedStatuses', () {
    test('contains running and created', () {
      expect(notExitedStatuses, containsAll(['running', 'created']));
    });
  });

  group('CompositeWaitStrategy', () {
    test('delegates withStartupTimeout to all children', () {
      final child1 = LogMessageWaitStrategy('a');
      final child2 = LogMessageWaitStrategy('b');
      final composite = CompositeWaitStrategy([child1, child2]);
      composite.withStartupTimeout(const Duration(seconds: 42));
      expect(child1.startupTimeout, equals(const Duration(seconds: 42)));
      expect(child2.startupTimeout, equals(const Duration(seconds: 42)));
    });

    test('delegates withPollInterval to all children', () {
      final child1 = PortWaitStrategy(8080);
      final child2 = LogMessageWaitStrategy('ready');
      final composite = CompositeWaitStrategy([child1, child2]);
      composite.withPollInterval(const Duration(seconds: 2));
      expect(child1.pollInterval, equals(const Duration(seconds: 2)));
      expect(child2.pollInterval, equals(const Duration(seconds: 2)));
    });

    test('delegates withTransientExceptions to all children — fluent return',
        () {
      final child1 = LogMessageWaitStrategy('a');
      final child2 = PortWaitStrategy(8080);
      final composite = CompositeWaitStrategy([child1, child2]);
      // Fluent call must return the composite itself and must not throw.
      final result = composite.withTransientExceptions([FormatException]);
      expect(identical(result, composite), isTrue);
    });

    test(
        'withTransientExceptions propagates to child strategies — behavioral '
        'verification', () async {
      // FormatException is NOT transient by default. After registering it via
      // the composite, the child strategy must also swallow it (i.e. poll
      // continues until timeout instead of rethrowing).
      final child = LogMessageWaitStrategy('never-appears')
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));
      final composite = CompositeWaitStrategy([child]);

      // Register FormatException as transient on the composite → must delegate
      // to child.
      composite.withTransientExceptions([FormatException]);

      when(() => target.logs()).thenAnswer((_) async {
        throw const FormatException('transient noise from child');
      });

      // If delegation works, the child swallows FormatException and times out
      // with TimeoutException. If delegation did NOT work, FormatException would
      // propagate immediately.
      await expectLater(
        child.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('withStartupTimeout returns this', () {
      final composite = CompositeWaitStrategy([]);
      final result = composite.withStartupTimeout(const Duration(seconds: 10));
      expect(identical(result, composite), isTrue);
    });

    test('works with empty strategy list', () async {
      final composite = CompositeWaitStrategy([]);
      await expectLater(
        composite.waitUntilReady(target),
        completes,
      );
    });

    test('strategies list is unmodifiable', () {
      final child = LogMessageWaitStrategy('x');
      final composite = CompositeWaitStrategy([child]);
      expect(
        () => composite.strategies.add(child),
        throwsUnsupportedError,
      );
    });

    test('runs all strategies in sequence and succeeds', () async {
      // Both strategies succeed immediately with the default mock setup.
      final s1 = LogMessageWaitStrategy('foo');
      final s2 = LogMessageWaitStrategy('bar');
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('foo bar'.codeUnits),
          Uint8List(0),
        ),
      );
      final composite = CompositeWaitStrategy([s1, s2])
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(composite.waitUntilReady(target), completes);
    });

    test('propagates first strategy failure — second is skipped', () async {
      // s1 cannot find 'NEVER_SEEN'; s2 would match 'bar' but is never reached.
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('bar'.codeUnits),
          Uint8List(0),
        ),
      );
      final s1 = LogMessageWaitStrategy('NEVER_SEEN')
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      final s2 = LogMessageWaitStrategy('bar');
      final composite = CompositeWaitStrategy([s1, s2]);
      await expectLater(
        composite.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('WaitStrategy Duration support', () {
    test('withStartupTimeout accepts Duration', () {
      final strategy = LogMessageWaitStrategy('x');
      strategy.withStartupTimeout(const Duration(seconds: 30));
      expect(strategy.startupTimeout, equals(const Duration(seconds: 30)));
    });

    test('withPollInterval accepts Duration', () {
      final strategy = LogMessageWaitStrategy('x');
      strategy.withPollInterval(const Duration(milliseconds: 500));
      expect(strategy.pollInterval, equals(const Duration(milliseconds: 500)));
    });

    test('withStartupTimeout returns this', () {
      final strategy = LogMessageWaitStrategy('x');
      final result = strategy.withStartupTimeout(const Duration(seconds: 30));
      expect(identical(result, strategy), isTrue);
    });

    test('withPollInterval returns this', () {
      final strategy = LogMessageWaitStrategy('x');
      final result = strategy.withPollInterval(const Duration(seconds: 1));
      expect(identical(result, strategy), isTrue);
    });

    test('startup timeout defaults are positive', () {
      final strategy = LogMessageWaitStrategy('x');
      expect(strategy.startupTimeout, greaterThan(Duration.zero));
      expect(strategy.pollInterval, greaterThan(Duration.zero));
    });
  });

  group('LogMessageWaitStrategy initialization', () {
    test('stores string as pattern', () {
      final strategy = LogMessageWaitStrategy('test message');
      expect(strategy.message.toString(), equals('test message'));
    });

    test('stores RegExp directly', () {
      final pattern = RegExp(r'test\d+');
      final strategy = LogMessageWaitStrategy(pattern);
      expect(strategy.message, same(pattern));
    });

    test('defaults times to 1', () {
      final strategy = LogMessageWaitStrategy('x');
      expect(strategy.times, equals(1));
    });

    test('stores custom times', () {
      final strategy = LogMessageWaitStrategy('x', times: 3);
      expect(strategy.times, equals(3));
    });

    test('defaults predicateStreamsAnd to false', () {
      final strategy = LogMessageWaitStrategy('x');
      expect(strategy.predicateStreamsAnd, isFalse);
    });

    test('stores predicateStreamsAnd = true', () {
      final strategy = LogMessageWaitStrategy('x', predicateStreamsAnd: true);
      expect(strategy.predicateStreamsAnd, isTrue);
    });

    test('predicateStreamsAnd=true succeeds when message in both streams',
        () async {
      final msg = Uint8List.fromList('Ready!'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (msg, msg), // message in BOTH stdout and stderr
      );

      final strategy = LogMessageWaitStrategy(
        'Ready!',
        predicateStreamsAnd: true,
      )..withStartupTimeout(const Duration(seconds: 5));

      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('predicateStreamsAnd=true fails when message only in stdout',
        () async {
      final found = Uint8List.fromList('Ready!'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (found, Uint8List(0)), // message NOT in stderr
      );

      final strategy = LogMessageWaitStrategy(
        'Ready!',
        predicateStreamsAnd: true,
      )..withStartupTimeout(const Duration(milliseconds: 100));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<Exception>()),
      );
    });

    test('predicateStreamsAnd=true fails when message only in stderr',
        () async {
      // Symmetric test: message is in stderr but NOT in stdout — still fails.
      final found = Uint8List.fromList('Ready!'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), found), // stdout empty, stderr has message
      );

      final strategy = LogMessageWaitStrategy(
        'Ready!',
        predicateStreamsAnd: true,
      )..withStartupTimeout(const Duration(milliseconds: 100));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<Exception>()),
      );
    });

    test(
        'predicateStreamsAnd=false succeeds when message appears only in stderr',
        () async {
      // Default OR mode: stderr match alone must satisfy the strategy.
      final found = Uint8List.fromList('Server ready'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), found), // stdout empty, stderr matches
      );

      final strategy = LogMessageWaitStrategy('Server ready')
        ..withStartupTimeout(const Duration(seconds: 5));

      await expectLater(strategy.waitUntilReady(target), completes);
    });
  });

  group('notExitedStatuses set', () {
    test('has exactly two entries', () {
      expect(notExitedStatuses.length, equals(2));
    });

    test('contains running and created only', () {
      expect(notExitedStatuses, equals({'running', 'created'}));
    });
  });

  group('withTransientExceptions', () {
    test('registering the same type twice does not create duplicates', () {
      // The _transientExceptions backing store is a Set, so adding
      // SocketException twice must leave it with exactly one entry for
      // SocketException (in addition to the default TimeoutException).
      final strategy = LogMessageWaitStrategy('x')
        ..withTransientExceptions([SocketException])
        ..withTransientExceptions([SocketException]);

      // We cannot inspect the private set directly, but we can verify that
      // the second call returns the strategy itself (fluent API check).
      final result = strategy.withTransientExceptions([FormatException]);
      expect(identical(result, strategy), isTrue);
    });

    test('withTransientExceptions returns this', () {
      final strategy = LogMessageWaitStrategy('x');
      final result = strategy.withTransientExceptions([FormatException]);
      expect(identical(result, strategy), isTrue);
    });
  });

  group('PortWaitStrategy initialization', () {
    test('stores port', () {
      final strategy = PortWaitStrategy(8080);
      expect(strategy.port, equals(8080));
    });
  });

  group('PortWaitStrategy.waitUntilReady', () {
    test('succeeds when a real TCP server is listening on the port', () async {
      // Bind to a random free port so we know something is listening.
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final listeningPort = server.port;
      // The mock target returns '127.0.0.1' and maps the port as-is.
      final strategy = PortWaitStrategy(listeningPort)
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close();
      }
    });

    test('throws TimeoutException when no server is listening', () async {
      // Bind then immediately close: no process keeps the port open.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();

      final strategy = PortWaitStrategy(freePort)
        ..withStartupTimeout(const Duration(milliseconds: 300))
        ..withPollInterval(const Duration(milliseconds: 50));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('TimeoutException message contains the port number', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();

      final strategy = PortWaitStrategy(freePort)
        ..withStartupTimeout(const Duration(milliseconds: 200))
        ..withPollInterval(const Duration(milliseconds: 50));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains(freePort.toString()),
          ),
        ),
      );
    });
  });

  group('ExecWaitStrategy initialization', () {
    test('stores command as unmodifiable list', () {
      final cmd = ['pg_isready', '-U', 'postgres'];
      final strategy = ExecWaitStrategy(cmd);
      expect(strategy.command, equals(cmd));
      expect(
        () => strategy.command.add('extra'),
        throwsUnsupportedError,
      );
    });

    test('defaults expectedExitCode to 0', () {
      final strategy = ExecWaitStrategy(['echo', 'hello']);
      expect(strategy.expectedExitCode, equals(0));
    });

    test('stores custom expectedExitCode', () {
      final strategy = ExecWaitStrategy(['cmd'], expectedExitCode: 1);
      expect(strategy.expectedExitCode, equals(1));
    });

    test('ExecWaitStrategy.shell wraps command in list', () {
      final strategy = ExecWaitStrategy.shell('pg_isready');
      expect(strategy.command, equals(['pg_isready']));
    });

    test('ExecWaitStrategy.shell forwards custom expectedExitCode', () {
      // Verify the factory propagates expectedExitCode through to the instance.
      final strategy = ExecWaitStrategy.shell('check.sh', expectedExitCode: 2);
      expect(strategy.command, equals(['check.sh']));
      expect(strategy.expectedExitCode, equals(2));
    });
  });

  group('ExecWaitStrategy.waitUntilReady', () {
    test('succeeds when exec returns expected exit code 0', () async {
      // Default mock: exec returns (0, empty) — matches default expectedExitCode.
      final strategy = ExecWaitStrategy(['pg_isready'])
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('succeeds with custom expectedExitCode when exec matches', () async {
      when(() => target.exec(any())).thenAnswer(
        (_) async => (1, Uint8List(0)),
      );
      final strategy = ExecWaitStrategy(['cmd'], expectedExitCode: 1)
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('throws TimeoutException when exec never returns expected exit code',
        () async {
      // Exec returns exit code 1, but strategy expects 0.
      when(() => target.exec(any())).thenAnswer(
        (_) async => (1, Uint8List(0)),
      );
      final strategy = ExecWaitStrategy(['pg_isready'])
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('TimeoutException message contains the command and expected exit code',
        () async {
      when(() => target.exec(any())).thenAnswer(
        (_) async => (1, Uint8List(0)),
      );
      // expectedExitCode=0; exec always returns 1 → timeout.
      final strategy = ExecWaitStrategy(['pg_isready', '-U', 'postgres'])
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            allOf(contains('pg_isready'), contains('0')),
          ),
        ),
      );
    });
  });

  group('FileExistsWaitStrategy initialization', () {
    test('stores filePath', () {
      final strategy = FileExistsWaitStrategy('/tmp/ready');
      expect(strategy.filePath, equals('/tmp/ready'));
    });

    test('succeeds immediately when exec returns exit code 0', () async {
      when(() => target.exec(['test', '-f', '/tmp/ready'])).thenAnswer(
        (_) async => (0, Uint8List(0)),
      );
      final strategy = FileExistsWaitStrategy('/tmp/ready')
        ..withStartupTimeout(
          const Duration(seconds: 5),
        );
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('throws TimeoutException when exec always returns non-zero', () async {
      when(() => target.exec(any())).thenAnswer(
        (_) async => (1, Uint8List(0)),
      );
      final strategy = FileExistsWaitStrategy('/tmp/ready')
        ..withStartupTimeout(
          const Duration(milliseconds: 50),
        )
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
        'TimeoutException message includes filePath and directory listing hint',
        () async {
      when(() => target.exec(any())).thenAnswer(
        (_) async => (1, Uint8List(0)),
      );
      final strategy = FileExistsWaitStrategy('/app/server.pid')
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/app/server.pid'),
              contains('Parent directory contents'),
            ),
          ),
        ),
      );
    });

    test(
        'TimeoutException message uses (unavailable) when diagnostic ls throws',
        () async {
      // Make every exec call throw SocketException.
      // During polling: SocketException is transient → swallowed → poll times
      // out with ready = false.
      // After timeout: the diagnostic ls call also throws → catch (_) ignores
      // it → listing stays at the default '(unavailable)'.
      when(() => target.exec(any())).thenAnswer(
        (_) async => throw const SocketException('exec unavailable'),
      );
      final strategy = FileExistsWaitStrategy('/tmp/marker')
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('(unavailable)'),
          ),
        ),
      );
    });

    test(
        'diagnostic ls output is included in the TimeoutException message when '
        'exec succeeds', () async {
      // 'test -f' returns non-zero (file absent).
      // 'ls -la /tmp' returns zero with some output.
      when(() => target.exec(['test', '-f', '/tmp/missing'])).thenAnswer(
        (_) async => (1, Uint8List(0)),
      );
      when(
        () => target.exec(['ls', '-la', '/tmp']),
      ).thenAnswer(
        (_) async => (0, Uint8List.fromList('drwxr-xr-x /tmp'.codeUnits)),
      );
      final strategy = FileExistsWaitStrategy('/tmp/missing')
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('drwxr-xr-x /tmp'),
          ),
        ),
      );
    });
  });

  group('HttpWaitStrategy.fromUrl', () {
    test('parses http URL into port and path', () {
      final s = HttpWaitStrategy.fromUrl('http://localhost:8080/api/health');
      expect(s.port, equals(8080));
      expect(s.path, equals('/api/health'));
    });

    test('parses https URL and enables TLS', () {
      final s = HttpWaitStrategy.fromUrl('https://localhost:8443/health');
      expect(s.port, equals(8443));
      expect(s.path, equals('/health'));
    });

    test('uses default port 80 for http without explicit port', () {
      final s = HttpWaitStrategy.fromUrl('http://localhost/health');
      expect(s.port, equals(80));
    });

    test('uses default port 443 for https without explicit port', () {
      final s = HttpWaitStrategy.fromUrl('https://localhost/health');
      expect(s.port, equals(443));
    });

    test('uses / when path is empty', () {
      final s = HttpWaitStrategy.fromUrl('http://localhost:9090');
      expect(s.path, equals('/'));
    });
  });

  group('HttpWaitStrategy internal state', () {
    test('withBasicCredentials encodes Authorization header correctly', () {
      // 'user:pass' as UTF-8 → base64 = 'dXNlcjpwYXNz'
      final s = HttpWaitStrategy(8080).withBasicCredentials('user', 'pass');
      expect(
        s.testHeaders['Authorization'],
        equals('Basic dXNlcjpwYXNz'),
      );
    });

    test('withBasicCredentials with special chars in password', () {
      // Verify the full string 'admin:p@ssw0rd!#' is correctly encoded.
      final s =
          HttpWaitStrategy(8080).withBasicCredentials('admin', 'p@ssw0rd!#');
      // Decode to verify round-trip correctness.
      final header = s.testHeaders['Authorization']!;
      expect(header.startsWith('Basic '), isTrue);
      final decoded = String.fromCharCodes(base64.decode(header.substring(6)));
      expect(decoded, equals('admin:p@ssw0rd!#'));
    });

    test('withHeader sets exact header name and value', () {
      final s = HttpWaitStrategy(8080)
          .withHeader('X-Custom-Header', 'some-value')
          .withHeader('Accept', 'application/json');
      expect(s.testHeaders['X-Custom-Header'], equals('some-value'));
      expect(s.testHeaders['Accept'], equals('application/json'));
    });

    test('withMethod uppercases the method', () {
      final s = HttpWaitStrategy(8080).withMethod('post');
      expect(s.testMethod, equals('POST'));
    });

    test('withMethod preserves already-uppercased method', () {
      final s = HttpWaitStrategy(8080).withMethod('PUT');
      expect(s.testMethod, equals('PUT'));
    });

    test('default method is GET', () {
      final s = HttpWaitStrategy(8080);
      expect(s.testMethod, equals('GET'));
    });

    test('forStatusCode adds code to the accepted set', () {
      final s = HttpWaitStrategy(8080).forStatusCode(201).forStatusCode(204);
      expect(s.testStatusCodes, containsAll([200, 201, 204]));
    });

    test('default accepted status codes contain only 200', () {
      final s = HttpWaitStrategy(8080);
      expect(s.testStatusCodes, equals({200}));
    });

    test('testHeaders is unmodifiable', () {
      final s = HttpWaitStrategy(8080).withHeader('X-Test', 'value');
      expect(
        () => s.testHeaders['X-Bad'] = 'mutate',
        throwsUnsupportedError,
      );
    });

    test('testStatusCodes is unmodifiable', () {
      final s = HttpWaitStrategy(8080);
      expect(
        () => s.testStatusCodes.add(999),
        throwsUnsupportedError,
      );
    });
  });

  group('HttpWaitStrategy builder methods', () {
    test('constructor stores port and normalises path', () {
      final s = HttpWaitStrategy(8080, path: '/health');
      expect(s.port, equals(8080));
      expect(s.path, equals('/health'));
    });

    test('constructor prepends / when path missing leading slash', () {
      final s = HttpWaitStrategy(8080, path: 'health');
      expect(s.path, equals('/health'));
    });

    test('default path is /', () {
      final s = HttpWaitStrategy(8080);
      expect(s.path, equals('/'));
    });

    test('forStatusCode returns this for chaining', () {
      final s = HttpWaitStrategy(8080);
      final result = s.forStatusCode(201);
      expect(identical(result, s), isTrue);
    });

    test('forStatusCodeMatching returns this for chaining', () {
      final s = HttpWaitStrategy(8080);
      final result = s.forStatusCodeMatching((code) => code < 400);
      expect(identical(result, s), isTrue);
    });

    test('forResponsePredicate returns this for chaining', () {
      final s = HttpWaitStrategy(8080);
      final result = s.forResponsePredicate((body) => body.contains('ok'));
      expect(identical(result, s), isTrue);
    });

    test('usingTls returns this for chaining', () {
      final s = HttpWaitStrategy(8443);
      final result = s.usingTls();
      expect(identical(result, s), isTrue);
    });

    test('withHeader returns this for chaining', () {
      final s = HttpWaitStrategy(8080);
      final result = s.withHeader('X-Custom', 'value');
      expect(identical(result, s), isTrue);
    });

    test('withBasicCredentials returns this for chaining', () {
      final s = HttpWaitStrategy(8080);
      final result = s.withBasicCredentials('user', 'pass');
      expect(identical(result, s), isTrue);
    });

    test('withMethod upper-cases the method and returns this', () {
      final s = HttpWaitStrategy(8080);
      final result = s.withMethod('post');
      expect(identical(result, s), isTrue);
    });

    test('withBody returns this for chaining', () {
      final s = HttpWaitStrategy(8080);
      final result = s.withBody('{"key":"value"}');
      expect(identical(result, s), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // WaitStrategy.poll non-transient exception propagation
  // ---------------------------------------------------------------------------
  group('WaitStrategy.poll exception behaviour', () {
    test('non-transient exception is rethrown immediately', () async {
      // ArgumentError is not in the default transient set, so it must propagate.
      when(() => target.logs()).thenAnswer((_) async {
        throw ArgumentError('unexpected');
      });
      final strategy = LogMessageWaitStrategy('Server started')
        ..withStartupTimeout(const Duration(seconds: 5));

      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registered transient exception type is silently swallowed', () async {
      // FormatException is NOT transient by default — but after
      // withTransientExceptions([FormatException]) it must be swallowed.
      // After swallowing it long enough the timeout fires.
      when(() => target.logs()).thenAnswer((_) async {
        throw const FormatException('transient noise');
      });
      final strategy = LogMessageWaitStrategy('x')
        ..withTransientExceptions([FormatException])
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));

      // Should timeout (not rethrow FormatException).
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('SocketException is swallowed by default (always transient)',
        () async {
      // SocketException is in the default transient set — it must be swallowed
      // and polling must continue until the timeout fires.
      when(() => target.logs()).thenAnswer((_) async {
        throw const SocketException('connection refused');
      });
      final strategy = LogMessageWaitStrategy('Server started')
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));

      // SocketException is transient → poll runs until timeout, not rethrow.
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
        'subclass of SocketException is swallowed — _isTransient uses `is` for '
        'built-in types', () async {
      // _isTransient: `if (type == SocketException) return e is SocketException`
      // → subclasses of SocketException still match via `is`, so they are caught.
      when(() => target.logs()).thenAnswer((_) async {
        throw _SubSocketException();
      });
      final strategy = LogMessageWaitStrategy('never')
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));

      // _SubSocketException `is SocketException` → swallowed → poll times out.
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
        'subclass of TimeoutException is swallowed — _isTransient uses `is` for '
        'built-in types', () async {
      // _isTransient: `if (type == TimeoutException) return e is TimeoutException`
      // → subclasses of TimeoutException still match via `is`, so they are caught.
      when(() => target.logs()).thenAnswer((_) async {
        throw _SubTimeoutException();
      });
      final strategy = LogMessageWaitStrategy('never')
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));

      // _SubTimeoutException `is TimeoutException` → swallowed → poll times out.
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test(
        'subclass of user-registered exception is NOT swallowed — _isTransient '
        'uses runtimeType == for user types', () async {
      // After withTransientExceptions([FormatException]):
      //   _isTransient(e, FormatException): e.runtimeType == FormatException
      // A _SubFormatException has runtimeType = _SubFormatException ≠ FormatException
      // → NOT caught → propagates immediately.
      when(() => target.logs()).thenAnswer((_) async {
        throw const _SubFormatException();
      });
      final strategy = LogMessageWaitStrategy('never')
        ..withTransientExceptions([FormatException])
        ..withStartupTimeout(const Duration(seconds: 5));

      // _SubFormatException is NOT caught by the FormatException rule →
      // propagates rather than timing out.
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<_SubFormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // HealthcheckWaitStrategy
  // ---------------------------------------------------------------------------
  group('HealthcheckWaitStrategy', () {
    ContainerInspectInfo infoWithHealth(String healthStatus) =>
        ContainerInspectInfo(
          state: ContainerState(
            health: ContainerHealth(status: healthStatus),
          ),
        );

    test('succeeds immediately when health status is healthy', () async {
      when(() => target.containerInfo()).thenAnswer(
        (_) async => infoWithHealth('healthy'),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('throws StateError immediately when health status is unhealthy',
        () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('container logs'.codeUnits),
          Uint8List(0),
        ),
      );
      when(() => target.containerInfo()).thenAnswer(
        (_) async => infoWithHealth('unhealthy'),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unhealthy'),
          ),
        ),
      );
    });

    test('throws StateError when containerInfo returns null (no healthcheck)',
        () async {
      when(() => target.containerInfo()).thenAnswer((_) async => null);
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<StateError>()),
      );
    });

    test('keeps polling while health status is starting, then succeeds',
        () async {
      var callCount = 0;
      when(() => target.containerInfo()).thenAnswer((_) async {
        callCount++;
        return infoWithHealth(callCount < 3 ? 'starting' : 'healthy');
      });
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(strategy.waitUntilReady(target), completes);
      expect(callCount, greaterThanOrEqualTo(3));
    });

    test(
        'throws TimeoutException (not StateError) when health status is always '
        '"none" — not a special-cased value, treated as "keep waiting"',
        () async {
      // Docker's 'none' status means no healthcheck, but the implementation
      // does not special-case it — it falls through to `return false`, so
      // the poll loop runs until the timeout fires.
      when(() => target.containerInfo()).thenAnswer(
        (_) async => infoWithHealth('none'),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('unhealthy StateError message includes log output', () async {
      // The StateError thrown for 'unhealthy' must include the log content
      // in the form "Container is unhealthy. Logs: <log output>".
      const logContent = 'OOM killed at 12:00:00';
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList(logContent.codeUnits),
          Uint8List(0),
        ),
      );
      when(() => target.containerInfo()).thenAnswer(
        (_) async => infoWithHealth('unhealthy'),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unhealthy'),
              contains('Logs:'),
              contains(logContent),
            ),
          ),
        ),
      );
    });

    test(
        'throws StateError when containerInfo() throws — caught internally '
        'and treated as null (no healthcheck)', () async {
      // The implementation catches exceptions from containerInfo() and sets
      // healthStatus to null, which then triggers the "no health check" path.
      when(() => target.containerInfo()).thenAnswer(
        (_) async => throw StateError('inspect failed'),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<StateError>()),
      );
    });

    test(
        'throws StateError when health status is an empty string — isEmpty '
        'branch distinct from null branch', () async {
      // The condition is: `healthStatus == null || healthStatus.isEmpty`
      // The null branch is exercised by containerInfo() returning null.
      // This test specifically exercises the isEmpty branch (healthStatus == '').
      when(() => target.containerInfo()).thenAnswer(
        (_) async => const ContainerInspectInfo(
          state: ContainerState(
            health: ContainerHealth(status: ''),
          ),
        ),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no health check configured'),
          ),
        ),
      );
    });

    test(
        'throws StateError when health status is an empty string — error '
        'message includes target description', () async {
      // The error message ends with `: $target` — verify it's non-empty.
      when(() => target.containerInfo()).thenAnswer(
        (_) async => const ContainerInspectInfo(
          state: ContainerState(
            health: ContainerHealth(status: ''),
          ),
        ),
      );
      final strategy = HealthcheckWaitStrategy()
        ..withStartupTimeout(const Duration(milliseconds: 50))
        ..withPollInterval(const Duration(milliseconds: 10));
      Object? caught;
      try {
        await strategy.waitUntilReady(target);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      final msg = (caught as StateError).message;
      // Message must be non-trivially descriptive.
      expect(msg.length, greaterThan(10));
    });
  });

  // ---------------------------------------------------------------------------
  // LogMessageWaitStrategy times == 0 edge case
  // ---------------------------------------------------------------------------
  group('LogMessageWaitStrategy times = 0', () {
    test('succeeds immediately with empty logs when times=0', () async {
      // matches.length (0) >= times (0) is always true → immediate success
      // even with empty log output.
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), Uint8List(0)),
      );
      final strategy = LogMessageWaitStrategy('anything', times: 0)
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('succeeds immediately with non-empty logs when times=0', () async {
      // Even without any match, times=0 is trivially satisfied.
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('unrelated log line'.codeUnits),
          Uint8List(0),
        ),
      );
      final strategy = LogMessageWaitStrategy('xyz', times: 0)
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });
  });

  // ---------------------------------------------------------------------------
  // LogMessageWaitStrategy times > 1 behaviour
  // ---------------------------------------------------------------------------
  group('LogMessageWaitStrategy times > 1', () {
    test('fails when message appears only once but times=2', () async {
      // Log contains "Ready!" exactly once.
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('Ready!\n'.codeUnits),
          Uint8List(0),
        ),
      );
      final strategy = LogMessageWaitStrategy('Ready!', times: 2)
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<Exception>()),
      );
    });

    test('succeeds when message appears twice and times=2', () async {
      // Log contains "Ready!" exactly twice.
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('Ready!\nReady!\n'.codeUnits),
          Uint8List(0),
        ),
      );
      final strategy = LogMessageWaitStrategy('Ready!', times: 2)
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('succeeds when message appears exactly three times and times=3',
        () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('ping\nping\nping\n'.codeUnits),
          Uint8List(0),
        ),
      );
      final strategy = LogMessageWaitStrategy('ping', times: 3)
        ..withStartupTimeout(const Duration(seconds: 5));
      await expectLater(strategy.waitUntilReady(target), completes);
    });

    test('fails when message appears only twice but times=3', () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('ping\nping\n'.codeUnits),
          Uint8List(0),
        ),
      );
      final strategy = LogMessageWaitStrategy('ping', times: 3)
        ..withStartupTimeout(const Duration(milliseconds: 100))
        ..withPollInterval(const Duration(milliseconds: 20));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // waitForLogs free function
  // ---------------------------------------------------------------------------
  group('waitForLogs', () {
    test('returns a Duration when log message is found', () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('Server started'.codeUnits),
          Uint8List(0),
        ),
      );
      final elapsed = await waitForLogs(target, 'Server started');
      expect(elapsed, isA<Duration>());
      expect(elapsed.inMilliseconds, greaterThanOrEqualTo(0));
    });

    test('accepts a RegExp pattern', () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (
          Uint8List.fromList('Listening on port 8080'.codeUnits),
          Uint8List(0),
        ),
      );
      final elapsed = await waitForLogs(
        target,
        RegExp(r'Listening on port \d+'),
        timeout: const Duration(seconds: 5),
      );
      expect(elapsed, isA<Duration>());
    });

    test('throws when message not found before timeout', () async {
      when(() => target.logs()).thenAnswer(
        (_) async => (Uint8List(0), Uint8List(0)),
      );
      await expectLater(
        waitForLogs(
          target,
          'never-present-string',
          timeout: const Duration(milliseconds: 100),
          interval: const Duration(milliseconds: 20),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('predicateStreamsAnd=true succeeds when message found in both streams',
        () async {
      final msg = Uint8List.fromList('OK'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (msg, msg), // present in both stdout AND stderr
      );
      final elapsed = await waitForLogs(
        target,
        'OK',
        timeout: const Duration(seconds: 5),
        predicateStreamsAnd: true,
      );
      expect(elapsed, isA<Duration>());
    });

    test('predicateStreamsAnd=true times out when message only in stdout',
        () async {
      final msg = Uint8List.fromList('OK'.codeUnits);
      when(() => target.logs()).thenAnswer(
        (_) async => (msg, Uint8List(0)), // NOT in stderr
      );
      await expectLater(
        waitForLogs(
          target,
          'OK',
          timeout: const Duration(milliseconds: 100),
          interval: const Duration(milliseconds: 20),
          predicateStreamsAnd: true,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('elapsed Duration increases with actual wait time', () async {
      // Delay two poll intervals before the message appears, so the elapsed
      // time is measurably greater than zero.
      var callCount = 0;
      when(() => target.logs()).thenAnswer((_) async {
        callCount++;
        final content = callCount >= 3 ? 'Done' : '';
        return (Uint8List.fromList(content.codeUnits), Uint8List(0));
      });
      final elapsed = await waitForLogs(
        target,
        'Done',
        timeout: const Duration(seconds: 5),
        interval: const Duration(milliseconds: 20),
      );
      // At least two intervals must have elapsed before the message appeared.
      expect(elapsed.inMilliseconds, greaterThan(0));
    });
  });

  // ---------------------------------------------------------------------------
  // HttpWaitStrategy.waitUntilReady — real local HTTP server
  // ---------------------------------------------------------------------------
  group('HttpWaitStrategy.waitUntilReady', () {
    test('succeeds when HTTP server returns 200', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        req.response
          ..statusCode = HttpStatus.ok
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('throws TimeoutException when no HTTP server is listening', () async {
      // Bind then immediately close so nothing holds the port.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();

      final strategy = HttpWaitStrategy(freePort)
        ..withStartupTimeout(const Duration(milliseconds: 300))
        ..withPollInterval(const Duration(milliseconds: 50));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('TimeoutException message says "HTTP endpoint not ready"', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();

      final strategy = HttpWaitStrategy(freePort)
        ..withStartupTimeout(const Duration(milliseconds: 200))
        ..withPollInterval(const Duration(milliseconds: 50));
      await expectLater(
        strategy.waitUntilReady(target),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('HTTP endpoint not ready'),
          ),
        ),
      );
    });

    test('keeps polling when server returns 503 then eventually returns 200',
        () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        requestCount++;
        req.response
          ..statusCode =
              requestCount < 3 ? HttpStatus.serviceUnavailable : HttpStatus.ok
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..withStartupTimeout(const Duration(seconds: 5))
        ..withPollInterval(const Duration(milliseconds: 50));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
        expect(requestCount, greaterThanOrEqualTo(3));
      } finally {
        await server.close(force: true);
      }
    });

    test('succeeds with forStatusCodeMatching — accepts any 2xx code',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        // Return 201 Created — not in the default {200} set.
        req.response
          ..statusCode = HttpStatus.created
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..forStatusCodeMatching((code) => code >= 200 && code < 300)
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test(
        'forStatusCodeMatching takes precedence over forStatusCode — '
        'exact code set is ignored when the matcher is set', () async {
      // The server returns 202 Accepted. forStatusCode(200) is registered
      // (the default), but forStatusCodeMatching replaces the check entirely,
      // so 202 must succeed even though 202 is not in the exact-code set.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        req.response
          ..statusCode = HttpStatus.accepted // 202
          ..close();
      });
      // forStatusCode(200) is in the set but forStatusCodeMatching overrides it.
      final strategy = HttpWaitStrategy(port)
        ..forStatusCode(200)
        ..forStatusCodeMatching((code) => code == 202)
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('succeeds when forResponsePredicate matches body content', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        req.response
          ..statusCode = HttpStatus.ok
          ..write('{"status":"ready"}')
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..forResponsePredicate((body) => body.contains('"status":"ready"'))
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test(
        'times out when 200 is returned but forResponsePredicate never satisfied',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        // Responds 200 but body never matches the predicate.
        req.response
          ..statusCode = HttpStatus.ok
          ..write('{"status":"starting"}')
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..forResponsePredicate((body) => body.contains('"status":"ready"'))
        ..withStartupTimeout(const Duration(milliseconds: 200))
        ..withPollInterval(const Duration(milliseconds: 50));
      try {
        await expectLater(
          strategy.waitUntilReady(target),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('succeeds with forStatusCode — adds 201 to accepted set', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        req.response
          ..statusCode = 201
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..forStatusCode(201)
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('times out when server always returns 404 (not in accepted set)',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..withStartupTimeout(const Duration(milliseconds: 200))
        ..withPollInterval(const Duration(milliseconds: 50));
      try {
        await expectLater(
          strategy.waitUntilReady(target),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('succeeds on custom path when server handles it', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        // Return 200 only for /health; 404 for anything else.
        final code =
            req.uri.path == '/health' ? HttpStatus.ok : HttpStatus.notFound;
        req.response
          ..statusCode = code
          ..close();
      });
      final strategy = HttpWaitStrategy(port, path: '/health')
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('withMethod sends the specified HTTP method to the server', () async {
      // The strategy uses POST; the server returns 200 only for POST requests.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        final code =
            req.method == 'POST' ? HttpStatus.ok : HttpStatus.methodNotAllowed;
        req.response
          ..statusCode = code
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..withMethod('POST')
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('withHeader sends custom headers to the server', () async {
      // The server returns 200 only when the custom header is present and
      // has the expected value; 400 otherwise.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        final headerVal = req.headers.value('x-api-token');
        final code =
            headerVal == 'secret-token' ? HttpStatus.ok : HttpStatus.badRequest;
        req.response
          ..statusCode = code
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..withHeader('X-Api-Token', 'secret-token')
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('withBody sends the request body to the server', () async {
      // The server reads the body and returns 200 only if it matches.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        final code =
            body == '{"ping":true}' ? HttpStatus.ok : HttpStatus.badRequest;
        req.response.statusCode = code;
        unawaited(req.response.close());
      });
      final strategy = HttpWaitStrategy(port)
        ..withMethod('POST')
        ..withBody('{"ping":true}')
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });

    test('withBasicCredentials sends Authorization header to the server',
        () async {
      // The server returns 200 only for the correct Basic auth header.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((req) {
        final auth = req.headers.value('authorization');
        // 'admin:s3cr3t' base64-encoded = 'YWRtaW46czNjcjN0'
        final code = auth == 'Basic YWRtaW46czNjcjN0'
            ? HttpStatus.ok
            : HttpStatus.unauthorized;
        req.response
          ..statusCode = code
          ..close();
      });
      final strategy = HttpWaitStrategy(port)
        ..withBasicCredentials('admin', 's3cr3t')
        ..withStartupTimeout(const Duration(seconds: 5));
      try {
        await expectLater(strategy.waitUntilReady(target), completes);
      } finally {
        await server.close(force: true);
      }
    });
  });
}
