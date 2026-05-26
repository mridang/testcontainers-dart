/// Docker label constants and factory for testcontainers-managed resources.
///
/// Every container, network, and image created by this library is stamped with
/// a set of well-known `org.testcontainers.*` labels. The [Reaper] (ryuk)
/// reads these labels to identify and clean up orphaned resources.
library;

import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'config.dart';

/// The root namespace for all testcontainers Docker labels.
///
/// Any user-supplied label key that starts with this prefix is rejected by
/// [createLabels] because those keys are reserved for internal use.
const String testcontainersNamespace = 'org.testcontainers';

/// Label key indicating that the resource was created by testcontainers.
///
/// The value is always the string `'true'`.
const String labelTestcontainers = testcontainersNamespace;

/// Label key carrying the unique session identifier.
///
/// Its value is the process-scoped [sessionId] UUID.  The [Reaper] uses this
/// label to find and remove all resources belonging to the current test
/// process after the process exits.
const String labelSessionId = 'org.testcontainers.session-id';

/// Label key carrying the testcontainers library version.
///
/// The value is [tcVersion].
const String labelVersion = 'org.testcontainers.version';

/// Label key identifying the language binding.
///
/// The value is always [labelLangValue] (`'dart'`).
const String labelLang = 'org.testcontainers.lang';

/// The current version of this Dart testcontainers library.
///
/// Lazily resolved at first access by locating the package's own
/// `pubspec.yaml` via `.dart_tool/package_config.json`. Falls back to
/// `'unknown'` if the config cannot be read (e.g. in unusual environments).
/// Stamped on every container, network, and image resource via [labelVersion].
final String tcVersion = _readTcVersion();

String _readTcVersion() {
  try {
    var dir = Directory.current;
    for (var i = 0; i < 10; i++) {
      final configFile = File('${dir.path}/.dart_tool/package_config.json');
      if (configFile.existsSync()) {
        final config =
            jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
        final packages =
            (config['packages'] as List).cast<Map<String, dynamic>>();
        final pkg = packages.firstWhere(
          (p) => p['name'] == 'testcontainers_core',
          orElse: () => <String, dynamic>{},
        );
        if (pkg.isNotEmpty) {
          final rootUri = pkg['rootUri'] as String;
          final pkgRoot = configFile.parent.uri.resolve(rootUri);
          final pubspecFile = File.fromUri(pkgRoot.resolve('pubspec.yaml'));
          if (pubspecFile.existsSync()) {
            final m = RegExp(
              r'^version:\s+(\S+)',
              multiLine: true,
            ).firstMatch(pubspecFile.readAsStringSync());
            if (m != null) return m.group(1)!;
          }
        }
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  } catch (_) {}
  return 'unknown';
}

/// The language binding identifier placed in [labelLang].
const String labelLangValue = 'dart';

/// A UUID that is unique to the current Dart process.
///
/// Created once at module initialisation and reused for every container,
/// network, and image created during the lifetime of the process. The
/// [Reaper] (ryuk) registers this session ID so that Docker resources are
/// removed when the process terminates.
final String sessionId = const Uuid().v4();

/// Returns the standard set of Docker labels for a container or network.
///
/// Merges the caller-supplied [labels] map with the four built-in
/// testcontainers labels:
///
/// | Label key | Value |
/// |---|---|
/// | `org.testcontainers` | `'true'` |
/// | `org.testcontainers.version` | [tcVersion] |
/// | `org.testcontainers.lang` | `'dart'` |
/// | `org.testcontainers.session-id` | [sessionId] (omitted for ryuk) |
///
/// Parameters:
/// - [image] — the image name being used. When [image] matches the configured
///   ryuk image, the session-id label is **omitted** so that ryuk itself is
///   not tracked by another ryuk instance.
/// - [labels] — optional caller-supplied labels. May be `null` (treated as
///   empty). Must not contain any key that starts with
///   `org.testcontainers` — doing so throws an [ArgumentError].
///
/// Throws [ArgumentError] if any key in [labels] starts with the reserved
/// `org.testcontainers` namespace.
Map<String, String> createLabels(
  String image,
  Map<String, String>? labels,
) {
  final effective = labels ?? const <String, String>{};
  for (final k in effective.keys) {
    if (k.startsWith(testcontainersNamespace)) {
      throw ArgumentError(
        'The org.testcontainers namespace is reserved for internal use',
      );
    }
  }
  return {
    ...effective,
    labelLang: labelLangValue,
    labelTestcontainers: 'true',
    labelVersion: tcVersion,
    if (image !=
        testcontainersConfig.hubImageNamePrefix +
            testcontainersConfig.ryukImage)
      labelSessionId: sessionId,
  };
}
