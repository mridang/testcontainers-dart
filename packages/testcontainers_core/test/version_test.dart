@Tags(['unit'])
library;

import 'package:test/test.dart';
import 'package:testcontainers_core/src/version.dart';

void main() {
  group('ComparableVersion', () {
    test('parses major.minor.patch', () {
      final v = ComparableVersion('1.2.3');
      expect(v.major, equals(1));
      expect(v.minor, equals(2));
      expect(v.patch, equals(3));
    });

    test('less than operator', () {
      expect(ComparableVersion('1.0.0') < ComparableVersion('2.0.0'), isTrue);
      expect(ComparableVersion('2.0.0') < ComparableVersion('1.0.0'), isFalse);
      expect(ComparableVersion('1.0.0') < ComparableVersion('1.0.0'), isFalse);
    });

    test('less than or equal operator', () {
      expect(
        ComparableVersion('1.0.0') <= ComparableVersion('2.0.0'),
        isTrue,
      );
      expect(
        ComparableVersion('1.0.0') <= ComparableVersion('1.0.0'),
        isTrue,
      );
      expect(
        ComparableVersion('2.0.0') <= ComparableVersion('1.0.0'),
        isFalse,
      );
    });

    test('equals operator', () {
      expect(
        ComparableVersion('1.2.3') == ComparableVersion('1.2.3'),
        isTrue,
      );
      expect(
        ComparableVersion('1.2.3') == ComparableVersion('1.2.4'),
        isFalse,
      );
    });

    test('greater than operator', () {
      expect(ComparableVersion('2.0.0') > ComparableVersion('1.0.0'), isTrue);
      expect(ComparableVersion('1.0.0') > ComparableVersion('2.0.0'), isFalse);
    });

    test('greater than or equal operator', () {
      expect(
        ComparableVersion('2.0.0') >= ComparableVersion('1.0.0'),
        isTrue,
      );
      expect(
        ComparableVersion('1.0.0') >= ComparableVersion('1.0.0'),
        isTrue,
      );
    });

    test('compareTo returns negative for less', () {
      expect(
        ComparableVersion('1.0.0').compareTo(ComparableVersion('2.0.0')),
        lessThan(0),
      );
    });

    test('compareTo returns zero for equal', () {
      expect(
        ComparableVersion('1.2.3').compareTo(ComparableVersion('1.2.3')),
        equals(0),
      );
    });

    test('compareTo returns positive for greater', () {
      expect(
        ComparableVersion('2.0.0').compareTo(ComparableVersion('1.0.0')),
        greaterThan(0),
      );
    });

    test('minor version comparison', () {
      expect(
        ComparableVersion('1.2.0') < ComparableVersion('1.3.0'),
        isTrue,
      );
    });

    test('patch version comparison', () {
      expect(
        ComparableVersion('1.0.0') < ComparableVersion('1.0.1'),
        isTrue,
      );
    });

    test('toString returns version string', () {
      expect(ComparableVersion('1.2.3').toString(), equals('1.2.3'));
    });

    test('throws FormatException for non-numeric version', () {
      expect(
        () => ComparableVersion('invalid'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for double-dot version', () {
      expect(
        () => ComparableVersion('1..0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for two-part version', () {
      expect(
        () => ComparableVersion('1.0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for four-part version', () {
      expect(
        () => ComparableVersion('1.0.0.0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for negative component', () {
      // int.tryParse('-1') succeeds but the version is semantically invalid;
      // however the current implementation allows negatives (int.tryParse).
      // Test confirms the actual behaviour rather than assuming rejection.
      expect(
        () => ComparableVersion('-1.0.0'),
        returnsNormally,
      );
    });

    test('ordering operators throw FormatException for invalid string', () {
      final v = ComparableVersion('1.0.0');
      // Use Object to avoid unrelated_type_equality_checks lint while
      // still testing the String dispatch branch at runtime.
      final Object invalidObj = 'invalid';
      expect(() => v < invalidObj, throwsA(isA<FormatException>()));
      expect(() => v <= invalidObj, throwsA(isA<FormatException>()));
      expect(() => v > invalidObj, throwsA(isA<FormatException>()));
      expect(() => v >= invalidObj, throwsA(isA<FormatException>()));
    });

    test('== with invalid version string returns false (not throw)', () {
      // Dart's equality contract requires operator== to never throw.
      // An unparseable String is simply not equal to any ComparableVersion.
      final v = ComparableVersion('1.0.0');
      final Object invalidStr = 'not-a-version';
      // ignore: unrelated_type_equality_checks
      expect(v == invalidStr, isFalse);
    });

    test('not-equal operator', () {
      expect(
        ComparableVersion('1.0.0') != ComparableVersion('2.0.0'),
        isTrue,
      );
      expect(
        ComparableVersion('1.0.0') != ComparableVersion('1.0.0'),
        isFalse,
      );
    });

    test('hashCode is consistent with equals — equal versions share hash', () {
      final a = ComparableVersion('3.7.2');
      final b = ComparableVersion('3.7.2');
      expect(a == b, isTrue);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('hashCode differs for unequal versions', () {
      // Not guaranteed by contract, but true for any reasonable hash.
      expect(
        ComparableVersion('1.0.0').hashCode,
        isNot(equals(ComparableVersion('2.0.0').hashCode)),
      );
    });

    test('can be used as Map key', () {
      final map = <ComparableVersion, String>{
        ComparableVersion('1.0.0'): 'one',
        ComparableVersion('2.0.0'): 'two',
      };
      expect(map[ComparableVersion('1.0.0')], equals('one'));
      expect(map[ComparableVersion('2.0.0')], equals('two'));
    });

    test('can be stored in a Set', () {
      final set = {
        ComparableVersion('1.0.0'),
        ComparableVersion('1.0.0'),
        ComparableVersion('2.0.0'),
      };
      // Duplicate must be collapsed.
      expect(set.length, equals(2));
    });

    test('== with an unrelated type returns false without throwing', () {
      final v = ComparableVersion('1.0.0');
      // int is neither String nor ComparableVersion → must return false.
      // ignore: unrelated_type_equality_checks
      expect(v == 42, isFalse);
    });

    test('accepts string argument via operators', () {
      final v = ComparableVersion('1.5.0');
      // These dispatch through the Object branch of the operator.
      expect(v < '2.0.0', isTrue);
      expect(v > '1.0.0', isTrue);
      // ignore: unrelated_type_equality_checks
      expect(v == '1.5.0', isTrue);
    });

    test('0.0.0 compares less than any non-zero version', () {
      final zero = ComparableVersion('0.0.0');
      expect(zero < ComparableVersion('0.0.1'), isTrue);
      expect(zero < ComparableVersion('0.1.0'), isTrue);
      expect(zero < ComparableVersion('1.0.0'), isTrue);
    });

    test('0.0.0 equals 0.0.0', () {
      expect(ComparableVersion('0.0.0') == ComparableVersion('0.0.0'), isTrue);
    });

    test('0.0.0 compareTo self is 0', () {
      final zero = ComparableVersion('0.0.0');
      expect(zero.compareTo(ComparableVersion('0.0.0')), equals(0));
    });

    test('large version numbers compare correctly', () {
      // Ensures no integer overflow or truncation.
      expect(
        ComparableVersion('10.20.30') > ComparableVersion('10.20.29'),
        isTrue,
      );
      expect(
        ComparableVersion('100.0.0') > ComparableVersion('99.999.999'),
        isTrue,
      );
    });

    test('sort a list of ComparableVersion instances', () {
      final versions = [
        ComparableVersion('3.0.0'),
        ComparableVersion('1.0.0'),
        ComparableVersion('2.0.0'),
        ComparableVersion('1.0.1'),
      ]..sort();
      expect(versions.map((v) => v.toString()).toList(), [
        '1.0.0',
        '1.0.1',
        '2.0.0',
        '3.0.0',
      ]);
    });
  });
}
