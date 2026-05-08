@Tags(['unit'])
library;

import 'package:test/test.dart';
import 'package:testcontainers_core/src/config.dart';
import 'package:testcontainers_core/src/labels.dart';

void main() {
  group('createLabels', () {
    test('attaches required label keys', () {
      final labels = createLabels('nginx:latest', null);
      expect(labels[labelTestcontainers], equals('true'));
      expect(labels[labelVersion], equals(tcVersion));
      expect(labels[labelLang], equals(labelLangValue));
      expect(labels.containsKey(labelSessionId), isTrue);
    });

    test('omits session-id label for ryuk image', () {
      final labels = createLabels(testcontainersConfig.ryukImage, null);
      expect(labels.containsKey(labelSessionId), isFalse);
      expect(labels[labelTestcontainers], equals('true'));
    });

    test('merges user-supplied labels', () {
      final labels = createLabels('nginx:latest', {'app': 'myapp'});
      expect(labels['app'], equals('myapp'));
      expect(labels[labelTestcontainers], equals('true'));
    });

    test('throws when user label uses org.testcontainers prefix', () {
      expect(
        () => createLabels(
          'nginx:latest',
          {'org.testcontainers.custom': 'value'},
        ),
        throwsArgumentError,
      );
    });

    test('throws when user label is the exact namespace string', () {
      // 'org.testcontainers'.startsWith('org.testcontainers') is true.
      expect(
        () => createLabels('nginx:latest', {'org.testcontainers': 'value'}),
        throwsArgumentError,
      );
    });

    test('throws when user label starts with namespace but has no dot', () {
      // 'org.testcontainersXYZ' starts with 'org.testcontainers' → rejected.
      expect(
        () => createLabels(
          'nginx:latest',
          {'org.testcontainersXYZ': 'value'},
        ),
        throwsArgumentError,
      );
    });

    test('allows label that does not start with org.testcontainers', () {
      // Distinct prefix — must not throw.
      expect(
        () => createLabels(
          'nginx:latest',
          {'com.mycompany.label': 'value'},
        ),
        returnsNormally,
      );
    });

    test('sessionId is a non-empty string', () {
      expect(sessionId, isNotEmpty);
    });

    test('sessionId is a valid UUID v4', () {
      // A UUID v4 has the form:
      // xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      // where y is one of 8, 9, a, or b.
      final uuidV4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      expect(uuidV4.hasMatch(sessionId), isTrue);
    });

    test('labelLangValue is dart', () {
      expect(labelLangValue, equals('dart'));
    });

    test('tcVersion matches package version', () {
      expect(tcVersion, equals('0.1.0'));
    });

    test('sessionId is process-scoped — same value on two calls', () {
      final first = createLabels('not-ryuk', null);
      final second = createLabels('not-ryuk', null);
      expect(first[labelSessionId], equals(second[labelSessionId]));
    });

    test('createLabels does not mutate the input map', () {
      final input = <String, String>{'key': 'value'};
      final expected = Map<String, String>.from(input);
      createLabels('not-ryuk', input);
      expect(input, equals(expected));
    });

    test('createLabels with empty map adds 4 required keys', () {
      final labels = createLabels('nginx:latest', {});
      // 4 keys: labelTestcontainers, labelVersion, labelLang, labelSessionId.
      expect(labels, hasLength(4));
    });

    test('createLabels for ryuk image adds exactly 3 keys (no session-id)', () {
      final labels = createLabels(testcontainersConfig.ryukImage, {});
      // labelTestcontainers, labelVersion, labelLang — but NOT labelSessionId.
      expect(labels, hasLength(3));
      expect(labels.containsKey(labelSessionId), isFalse);
    });

    test('throws when any of multiple user labels has reserved prefix', () {
      // Even when some labels are fine, one bad label must still throw.
      expect(
        () => createLabels(
          'nginx:latest',
          {
            'com.example.ok': 'good',
            'org.testcontainers.bad': 'value', // reserved — triggers throw
            'net.app.other': 'fine',
          },
        ),
        throwsArgumentError,
      );
    });

    test('ArgumentError message mentions the reserved namespace', () {
      expect(
        () => createLabels(
          'nginx:latest',
          {'org.testcontainers.x': 'y'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message?.toString() ?? '',
            'message',
            contains('org.testcontainers'),
          ),
        ),
      );
    });

    test('createLabels result is a plain Map (not unmodifiable)', () {
      // The result must be a normal map so callers can safely add to it.
      final labels = createLabels('nginx:latest', {'key': 'val'});
      expect(() => labels['extra'] = 'ok', returnsNormally);
    });
  });

  group('Label constants', () {
    test('testcontainersNamespace is the root namespace', () {
      expect(testcontainersNamespace, equals('org.testcontainers'));
    });

    test('labelTestcontainers equals testcontainersNamespace', () {
      expect(labelTestcontainers, equals(testcontainersNamespace));
    });

    test('labelSessionId has correct value', () {
      expect(labelSessionId, equals('org.testcontainers.session-id'));
    });

    test('labelVersion has correct value', () {
      expect(labelVersion, equals('org.testcontainers.version'));
    });

    test('labelLang has correct value', () {
      expect(labelLang, equals('org.testcontainers.lang'));
    });
  });
}
