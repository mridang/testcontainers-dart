/// Utilities for copying files and directories into running containers.
///
/// The sealed [Transferable] hierarchy represents content that can be
/// transferred into a Docker container via the `PUT /containers/{id}/archive`
/// API endpoint. [buildTransferTar] packs a [Transferable] into an in-memory
/// tar archive ready to be sent over the Docker socket.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Default Unix file permission bits used when copying files into containers.
///
/// Equivalent to octal `0644` (owner read/write, group read, other read),
/// which is the conventional default for non-executable files on Linux.
const int kDefaultTransferMode = 0x1A4;

/// Base type for content that can be copied into a running container.
///
/// Use one of the two concrete sub-types:
/// - [BytesTransferable] — for in-memory byte data.
/// - [PathTransferable] — for a file or directory on the local filesystem.
///
/// Instances are created by the caller and passed to
/// [DockerContainer.withCopyIntoContainer] or
/// [DockerContainer.copyIntoContainer].
sealed class Transferable {}

/// Wraps raw bytes to be copied into a container.
///
/// The bytes are packed as a single file entry inside a tar archive and
/// placed at the `destination` path within the container.
///
/// Example:
/// ```dart
/// container.withCopyIntoContainer(
///   BytesTransferable(Uint8List.fromList(utf8.encode('hello'))),
///   '/app/hello.txt',
///   0x1A4, // 0o644
/// );
/// ```
class BytesTransferable extends Transferable {
  /// The raw content to place in the container.
  ///
  /// A defensive copy is made at construction time so that mutations to the
  /// original buffer after calling this constructor do not affect the
  /// transferred content.
  final Uint8List bytes;

  /// Creates a [BytesTransferable] from [bytes].
  ///
  /// A copy of [bytes] is stored internally; the caller may safely modify the
  /// original buffer afterwards.
  BytesTransferable(Uint8List bytes) : bytes = Uint8List.fromList(bytes);
}

/// Wraps a local [FileSystemEntity] (file or directory) to be copied into a
/// container.
///
/// - When [path] is a [File], the file is packed as a single entry.
/// - When [path] is a [Directory], all files within the directory tree are
///   packed recursively. The directory itself is placed at `destination` inside
///   the archive.
///
/// Example:
/// ```dart
/// container.withCopyIntoContainer(
///   PathTransferable(File('/tmp/config.yaml')),
///   '/etc/myapp/config.yaml',
///   0x1A4,
/// );
/// ```
class PathTransferable extends Transferable {
  /// The local file or directory to copy into the container.
  final FileSystemEntity path;

  /// Creates a [PathTransferable] from [path].
  PathTransferable(this.path);
}

/// A specification describing a single copy-into-container operation.
///
/// The three positional fields are:
/// 1. The [Transferable] data source.
/// 2. The `destination` entry name within the tar archive. When the archive
///    is extracted at `/` inside the container, this becomes the absolute
///    path of the copied file (e.g. `'app/config.yaml'` → `/app/config.yaml`).
/// 3. The Unix file permission bits (e.g. `0x1A4` = `0o644`). Defaults to
///    `0x1A4` when omitted from a [TransferSpec] record literal.
typedef TransferSpec = (Transferable data, String destination, int mode);

/// Builds an in-memory tar archive from [transferable] and returns the raw
/// bytes ready to be uploaded via `PUT /containers/{id}/archive?path=/`.
///
/// The archive contains a single entry (or multiple entries for a directory)
/// with `destination` as the path within the archive and [mode] as the Unix
/// permission bits.
///
/// Parameters:
/// - [transferable] — the content to pack. Must be a [BytesTransferable] or a
///   [PathTransferable] whose [FileSystemEntity] exists.
/// - `destination` — the path of the entry inside the tar archive. This
///   becomes the absolute path inside the container when extracted at `/`.
/// - [mode] — Unix permission bits. Defaults to `0x1A4` (`0o644`,
///   owner-read/write, group-read, other-read).
///
/// Throws [ArgumentError] when [transferable] is a [PathTransferable] whose
/// path neither exists as a file nor as a directory.
Uint8List buildTransferTar(
  Transferable transferable,
  String destination, {
  int mode = kDefaultTransferMode,
}) {
  final archive = Archive();

  switch (transferable) {
    case BytesTransferable(:final bytes):
      final entry = ArchiveFile(destination, bytes.length, bytes);
      entry.mode = mode;
      archive.addFile(entry);
    case PathTransferable(:final path):
      final entity = path;
      if (entity is File && entity.existsSync()) {
        final bytes = entity.readAsBytesSync();
        final entry = ArchiveFile(destination, bytes.length, bytes);
        entry.mode = mode;
        archive.addFile(entry);
      } else if (entity is Directory && entity.existsSync()) {
        final dirName = entity.path.split(RegExp(r'[/\\]')).last;
        final base = destination.endsWith('/') ? destination : '$destination/';
        for (final file in entity.listSync(recursive: true).whereType<File>()) {
          final relative = file.path.substring(entity.path.length);
          final entryName = '$base$dirName$relative'.replaceAll('\\', '/');
          final bytes = file.readAsBytesSync();
          final entry = ArchiveFile(entryName, bytes.length, bytes);
          entry.mode = mode;
          archive.addFile(entry);
        }
      } else {
        throw ArgumentError(
          'Path ${entity.path} is neither a file nor directory',
        );
      }
  }

  return Uint8List.fromList(TarEncoder().encode(archive));
}
