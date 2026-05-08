@Tags(['unit'])
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:testcontainers/src/auth.dart';

void main() {
  group('parseDockerAuthConfig', () {
    test('parses valid auths section', () {
      final authStr = base64.encode(utf8.encode('myuser:mypassword'));
      final config = jsonEncode({
        'auths': {
          'https://index.docker.io/v1/': {'auth': authStr},
        },
      });

      final result = parseDockerAuthConfig(config);
      expect(result, isNotNull);
      expect(result!.length, equals(1));
      expect(result.first.registry, equals('https://index.docker.io/v1/'));
      expect(result.first.username, equals('myuser'));
      expect(result.first.password, equals('mypassword'));
    });

    test('returns null when no auths section (credHelpers only)', () {
      final config = jsonEncode({
        'credHelpers': {
          '<aws_account_id>.dkr.ecr.<region>.amazonaws.com': 'ecr-login',
        },
      });
      final result = parseDockerAuthConfig(config);
      expect(result, isNull);
    });

    test('returns null when only credsStore present', () {
      final config = jsonEncode({'credsStore': 'ecr-login'});
      final result = parseDockerAuthConfig(config);
      expect(result, isNull);
    });

    test('parses multiple auths correctly', () {
      final auth1 = base64.encode(utf8.encode('user1:pass1'));
      final auth2 = base64.encode(utf8.encode('user_new:pass_new'));
      final auth3 = base64.encode(utf8.encode('abc:123'));
      final config = jsonEncode({
        'auths': {
          'localhost:5000': {'auth': auth1},
          'https://example.com': {'auth': auth2},
          'example2.com': {'auth': auth3},
        },
      });

      final result = parseDockerAuthConfig(config);
      expect(result, isNotNull);
      expect(result!.length, equals(3));
      expect(result[0].registry, equals('localhost:5000'));
      expect(result[0].username, equals('user1'));
      expect(result[0].password, equals('pass1'));
      expect(result[1].registry, equals('https://example.com'));
      expect(result[1].username, equals('user_new'));
      expect(result[1].password, equals('pass_new'));
      expect(result[2].registry, equals('example2.com'));
      expect(result[2].username, equals('abc'));
      expect(result[2].password, equals('123'));
    });

    test('returns null for unknown top-level key', () {
      final config = jsonEncode({'key': 'value'});
      final result = parseDockerAuthConfig(config);
      expect(result, isNull);
    });

    test('throws on invalid JSON', () {
      expect(
        () => parseDockerAuthConfig('not json'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('mixed config returns only auths entries', () {
      final auth1 = base64.encode(utf8.encode('user1:pass1'));
      final config = jsonEncode({
        'auths': {
          'localhost:5000': {'auth': auth1},
        },
        'credHelpers': {
          '<aws_account_id>.dkr.ecr.<region>.amazonaws.com': 'ecr-login',
        },
        'credsStore': 'ecr-login',
      });

      final result = parseDockerAuthConfig(config);
      expect(result, isNotNull);
      expect(result!.length, equals(1));
      expect(result.first.registry, equals('localhost:5000'));
      expect(result.first.username, equals('user1'));
      expect(result.first.password, equals('pass1'));
    });

    test('DockerAuthInfo record has correct fields', () {
      const info = (registry: 'reg', username: 'user', password: 'pass');
      expect(info.registry, equals('reg'));
      expect(info.username, equals('user'));
      expect(info.password, equals('pass'));
    });

    test('skips entry with no colon in decoded credentials', () {
      // Encode a credential string that has no ':' separator.
      final badAuth = base64.encode(utf8.encode('nocolon'));
      final config = jsonEncode({
        'auths': {
          'https://bad.example.com': {'auth': badAuth},
        },
      });
      // Should not throw — the entry is silently skipped with a warning.
      final result = parseDockerAuthConfig(config);
      expect(result, isNotNull);
      expect(result!, isEmpty);
    });

    test('skips malformed entry but keeps valid sibling entry', () {
      final badAuth = base64.encode(utf8.encode('nocolon'));
      final goodAuth = base64.encode(utf8.encode('user:pass'));
      final config = jsonEncode({
        'auths': {
          'bad.example.com': {'auth': badAuth},
          'good.example.com': {'auth': goodAuth},
        },
      });
      final result = parseDockerAuthConfig(config);
      expect(result, hasLength(1));
      expect(result!.first.registry, equals('good.example.com'));
      expect(result.first.username, equals('user'));
    });

    test('returns empty list for empty auths map', () {
      final config = jsonEncode({'auths': <String, dynamic>{}});
      final result = parseDockerAuthConfig(config);
      expect(result, isNotNull);
      expect(result!, isEmpty);
    });

    test('password may contain colons (only first colon is the separator)', () {
      // A PAT or password that itself contains colons must be handled correctly.
      final auth = base64.encode(utf8.encode('user:pass:with:colons'));
      final config = jsonEncode({
        'auths': {
          'registry.example.com': {'auth': auth},
        },
      });
      final result = parseDockerAuthConfig(config);
      expect(result, hasLength(1));
      expect(result!.first.username, equals('user'));
      expect(result.first.password, equals('pass:with:colons'));
    });

    test('result list is unmodifiable', () {
      final auth = base64.encode(utf8.encode('user:pass'));
      final config = jsonEncode({
        'auths': {
          'reg.example.com': {'auth': auth},
        },
      });
      final result = parseDockerAuthConfig(config)!;
      expect(
        () => result.add((registry: 'x', username: 'y', password: 'z')),
        throwsUnsupportedError,
      );
    });

    test('throws ArgumentError for structurally invalid JSON (TypeError)', () {
      // JSON is valid but the `auths` key is a list, not a map → TypeError
      // inside the parser, which must be wrapped as ArgumentError.
      final config = jsonEncode({'auths': ['not', 'a', 'map']});
      expect(
        () => parseDockerAuthConfig(config),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
