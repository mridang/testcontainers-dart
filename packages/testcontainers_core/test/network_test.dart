@Tags(['unit'])
library;

import 'package:test/test.dart';
import 'package:testcontainers_core/src/network.dart';

// UUID v4 format: xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx
final _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('Network constructor', () {
    test('name is a valid UUID v4', () {
      final network = Network();
      expect(network.name, matches(_uuidV4Pattern));
    });

    test('each Network instance gets a distinct name', () {
      final n1 = Network();
      final n2 = Network();
      expect(n1.name, isNot(equals(n2.name)));
    });
  });

  group('Network.id before create', () {
    test('id is null before create is called', () {
      final network = Network();
      expect(network.id, isNull);
    });
  });

  group('Network.remove before create', () {
    test('remove completes without error when create was never called',
        () async {
      // _networkId is null → remove() is a no-op; no Docker call is made.
      final network = Network();
      await expectLater(network.remove(), completes);
    });
  });

  group('Network.connect before create', () {
    test('connect throws StateError when network has not been created',
        () async {
      final network = Network();
      await expectLater(
        network.connect('some-container-id'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('create()'),
          ),
        ),
      );
    });

    test('connect with aliases also throws StateError before create', () async {
      final network = Network();
      await expectLater(
        network.connect(
          'container-xyz',
          networkAliases: ['my-alias'],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Network name uniqueness', () {
    test('100 networks all get distinct names', () {
      final names = List.generate(100, (_) => Network().name).toSet();
      expect(names.length, equals(100));
    });
  });
}
