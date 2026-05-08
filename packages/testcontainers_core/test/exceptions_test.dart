@Tags(['unit'])
library;

import 'package:test/test.dart';
import 'package:testcontainers_core/src/exceptions.dart';

void main() {
  group('ContainerStartException', () {
    test('has correct message and toString', () {
      const e = ContainerStartException('failed to start');
      expect(e.message, equals('failed to start'));
      expect(e.toString(), contains('ContainerStartException'));
      expect(e.toString(), contains('failed to start'));
    });

    test('implements Exception', () {
      expect(const ContainerStartException('x'), isA<Exception>());
    });

    test('can be thrown and caught as Exception', () {
      expect(
        () => throw const ContainerStartException('boom'),
        throwsA(isA<ContainerStartException>()),
      );
    });
  });

  group('ContainerConnectException', () {
    test('has correct message and toString', () {
      const e = ContainerConnectException('cannot connect');
      expect(e.message, equals('cannot connect'));
      expect(e.toString(), contains('ContainerConnectException'));
      expect(e.toString(), contains('cannot connect'));
    });

    test('implements Exception', () {
      expect(const ContainerConnectException('x'), isA<Exception>());
    });

    test('can be thrown and caught as Exception', () {
      expect(
        () => throw const ContainerConnectException('oops'),
        throwsA(isA<ContainerConnectException>()),
      );
    });
  });

  group('ContainerIsNotRunning', () {
    test('has correct message and toString', () {
      const e = ContainerIsNotRunning('not running');
      expect(e.message, equals('not running'));
      expect(e.toString(), contains('ContainerIsNotRunning'));
      expect(e.toString(), contains('not running'));
    });

    test('implements Exception', () {
      expect(const ContainerIsNotRunning('x'), isA<Exception>());
    });

    test('can be thrown and caught as Exception', () {
      expect(
        () => throw const ContainerIsNotRunning('dead'),
        throwsA(isA<ContainerIsNotRunning>()),
      );
    });
  });

  group('NoSuchPortExposed', () {
    test('has correct message and toString', () {
      const e = NoSuchPortExposed('port 8080 not exposed');
      expect(e.message, equals('port 8080 not exposed'));
      expect(e.toString(), contains('NoSuchPortExposed'));
      expect(e.toString(), contains('port 8080 not exposed'));
    });

    test('implements Exception', () {
      expect(const NoSuchPortExposed('x'), isA<Exception>());
    });

    test('can be thrown and caught as Exception', () {
      expect(
        () => throw const NoSuchPortExposed('9999'),
        throwsA(isA<NoSuchPortExposed>()),
      );
    });
  });

  group('Exception toString exact format', () {
    test('ContainerStartException toString has exact ClassName: message format',
        () {
      const e = ContainerStartException('boom');
      expect(e.toString(), equals('ContainerStartException: boom'));
    });

    test('ContainerConnectException toString has exact format', () {
      const e = ContainerConnectException('oops');
      expect(e.toString(), equals('ContainerConnectException: oops'));
    });

    test('ContainerIsNotRunning toString has exact format', () {
      const e = ContainerIsNotRunning('dead');
      expect(e.toString(), equals('ContainerIsNotRunning: dead'));
    });

    test('NoSuchPortExposed toString has exact format', () {
      const e = NoSuchPortExposed('9999');
      expect(e.toString(), equals('NoSuchPortExposed: 9999'));
    });

    test('all four exceptions can be caught as base Exception', () {
      // Verify that a generic catch (e) catches all four types.
      void throwAndCatchAsException(Exception ex) {
        // ignore: only_throw_errors
        try {
          throw ex;
        } on Exception catch (_) {}
      }

      throwAndCatchAsException(const ContainerStartException('a'));
      throwAndCatchAsException(const ContainerConnectException('b'));
      throwAndCatchAsException(const ContainerIsNotRunning('c'));
      throwAndCatchAsException(const NoSuchPortExposed('d'));
    });
  });

  group('Exception type isolation', () {
    test('ContainerStartException is NOT a ContainerConnectException', () {
      expect(
        const ContainerStartException('x'),
        isNot(isA<ContainerConnectException>()),
      );
    });

    test('ContainerIsNotRunning is NOT a ContainerStartException', () {
      expect(
        const ContainerIsNotRunning('x'),
        isNot(isA<ContainerStartException>()),
      );
    });

    test('NoSuchPortExposed is NOT a ContainerIsNotRunning', () {
      expect(
        const NoSuchPortExposed('x'),
        isNot(isA<ContainerIsNotRunning>()),
      );
    });

    test('each exception type is distinct — all four are separate classes', () {
      // Verify the four exception types are distinguishable at runtime.
      final exceptions = [
        const ContainerStartException('a'),
        const ContainerConnectException('b'),
        const ContainerIsNotRunning('c'),
        const NoSuchPortExposed('d'),
      ];
      // Each is uniquely typed; no two share the same runtimeType.
      final types = exceptions.map((e) => e.runtimeType).toSet();
      expect(types.length, equals(4));
    });
  });
}
