@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:testcontainers_core/src/transferable.dart';

void main() {
  group('buildTransferTar', () {
    test('produces a valid tar from bytes', () {
      final bytes = Uint8List.fromList('hello world'.codeUnits);
      final transferable = BytesTransferable(bytes);
      final tar = buildTransferTar(transferable, 'hello.txt');

      expect(tar, isNotEmpty);

      final archive = TarDecoder().decodeBytes(tar);
      expect(archive.files.length, equals(1));
      expect(archive.files.first.name, equals('hello.txt'));
      final content = archive.files.first.content;
      expect(String.fromCharCodes(content), equals('hello world'));
    });

    test('sets custom mode on tar entry', () {
      final bytes = Uint8List.fromList('data'.codeUnits);
      final transferable = BytesTransferable(bytes);
      final tar = buildTransferTar(transferable, 'data.txt', mode: 0x1FF);

      final archive = TarDecoder().decodeBytes(tar);
      expect(archive.files.first.mode, equals(0x1FF));
    });

    test('default mode is 0x1A4 (octal 644)', () {
      final bytes = Uint8List.fromList('data'.codeUnits);
      final transferable = BytesTransferable(bytes);
      final tar = buildTransferTar(transferable, 'data.txt');

      final archive = TarDecoder().decodeBytes(tar);
      expect(archive.files.first.mode, equals(0x1A4));
    });

    test('BytesTransferable holds bytes', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final t = BytesTransferable(bytes);
      expect(t.bytes, equals(bytes));
    });

    test('BytesTransferable makes a defensive copy', () {
      final original = Uint8List.fromList([10, 20, 30]);
      final t = BytesTransferable(original);
      // Mutate the original buffer after construction.
      original[0] = 99;
      // The stored bytes must be unchanged.
      expect(t.bytes[0], equals(10));
    });

    test('produces a valid tar from a file', () {
      final tmp = Directory.systemTemp.createTempSync('tc_test_');
      try {
        final file = File('${tmp.path}/hello.txt')
          ..writeAsBytesSync('file content'.codeUnits);
        final transferable = PathTransferable(file);
        final tar = buildTransferTar(
          transferable,
          '/dest/hello.txt',
          mode: 0x1ED,
        ); // 0o755

        final archive = TarDecoder().decodeBytes(tar);
        expect(archive.files.length, equals(1));
        expect(archive.files.first.name, equals('/dest/hello.txt'));
        expect(archive.files.first.mode, equals(0x1ED));
        final content = archive.files.first.content;
        expect(String.fromCharCodes(content), equals('file content'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('produces a tar from a directory', () {
      final tmp = Directory.systemTemp.createTempSync('tc_test_dir_');
      try {
        final srcDir = Directory('${tmp.path}/my_dir')..createSync();
        File('${srcDir.path}/a.txt').writeAsBytesSync('aaa'.codeUnits);

        final transferable = PathTransferable(srcDir);
        final tar = buildTransferTar(transferable, '/dest');

        final archive = TarDecoder().decodeBytes(tar);
        final names = archive.files.map((f) => f.name).toList();
        expect(names, anyElement(contains('my_dir')));
        expect(names, anyElement(contains('a.txt')));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('throws ArgumentError for non-existent file path', () {
      final transferable = PathTransferable(
        File(
          '/tmp/__does_not_exist_${DateTime.now().microsecondsSinceEpoch}__',
        ),
      );
      expect(
        () => buildTransferTar(transferable, '/tmp/bad'),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for non-existent directory path', () {
      // A PathTransferable wrapping a non-existent Directory falls to the
      // else branch in buildTransferTar and must throw ArgumentError.
      final transferable = PathTransferable(
        Directory(
          '/tmp/__no_such_dir_${DateTime.now().microsecondsSinceEpoch}__',
        ),
      );
      expect(
        () => buildTransferTar(transferable, '/dest'),
        throwsArgumentError,
      );
    });

    test('ArgumentError message contains the path for non-existent paths', () {
      const fakePath = '/tmp/__nonexistent_for_msg_check__';
      final transferable = PathTransferable(File(fakePath));
      expect(
        () => buildTransferTar(transferable, '/dest'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message?.toString() ?? '',
            'message',
            contains(fakePath),
          ),
        ),
      );
    });

    test('empty directory produces a tar with no file entries', () {
      final tmp = Directory.systemTemp.createTempSync('tc_empty_dir_');
      try {
        final emptyDir = Directory('${tmp.path}/empty')..createSync();
        final transferable = PathTransferable(emptyDir);
        final tar = buildTransferTar(transferable, '/dest');
        // A valid (non-null, non-empty) tar is produced, but it has no entries
        // because the directory contains no files.
        expect(tar, isNotEmpty);
        final archive = TarDecoder().decodeBytes(tar);
        expect(archive.files, isEmpty);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('kDefaultTransferMode equals 0o644 (octal 644, decimal 420)', () {
      expect(kDefaultTransferMode, equals(0x1A4));
      expect(kDefaultTransferMode, equals(420)); // 0o644 in decimal
    });

    test('default mode parameter equals kDefaultTransferMode', () {
      final bytes = Uint8List.fromList('check'.codeUnits);
      final tar = buildTransferTar(BytesTransferable(bytes), 'check.txt');
      final archive = TarDecoder().decodeBytes(tar);
      expect(archive.files.first.mode, equals(kDefaultTransferMode));
    });

    test('empty BytesTransferable produces a 0-byte entry in the tar', () {
      final tar =
          buildTransferTar(BytesTransferable(Uint8List(0)), 'empty.txt');
      final archive = TarDecoder().decodeBytes(tar);
      expect(archive.files, hasLength(1));
      expect(archive.files.first.name, equals('empty.txt'));
      expect(archive.files.first.size, equals(0));
    });

    test('PathTransferable stores the path reference', () {
      final file = File('/tmp/dummy.txt');
      final t = PathTransferable(file);
      expect(t.path, same(file));
    });

    test('BytesTransferable and PathTransferable are both Transferable', () {
      expect(BytesTransferable(Uint8List(0)), isA<Transferable>());
      expect(PathTransferable(File('/tmp')), isA<Transferable>());
    });
  });
}
