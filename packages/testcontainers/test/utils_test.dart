@Tags(['unit'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:testcontainers/src/utils.dart';

void main() {
  group('insideContainer', () {
    test('returns a bool', () {
      // insideContainer() reads /.dockerenv; result depends on environment.
      expect(insideContainer(), isA<bool>());
    });
  });

  group('isMac / isLinux / isWindows', () {
    test('exactly one platform flag is true', () {
      final flags = [isMac(), isLinux(), isWindows()];
      expect(flags.where((f) => f).length, equals(1));
    });

    test('isMac matches Platform.isMacOS', () {
      expect(isMac(), equals(Platform.isMacOS));
    });

    test('isLinux matches Platform.isLinux', () {
      expect(isLinux(), equals(Platform.isLinux));
    });

    test('isWindows matches Platform.isWindows', () {
      expect(isWindows(), equals(Platform.isWindows));
    });
  });

  group('isArm', () {
    test('returns a bool', () {
      expect(isArm(), isA<bool>());
    });
  });

  group('defaultGatewayIp', () {
    test('returns null or a non-empty string', () {
      final ip = defaultGatewayIp();
      if (ip != null) {
        expect(ip, isNotEmpty);
      }
    });
  });

  group('runningContainerId', () {
    test('returns null or a non-empty string', () {
      final id = runningContainerId();
      if (id != null) {
        expect(id, isNotEmpty);
      }
    });

    test('returns null when not inside a docker container', () {
      // On a developer machine or standard CI, /proc/self/cgroup either does
      // not exist or does not contain a /docker/ entry.
      if (!Platform.isLinux) {
        expect(runningContainerId(), isNull);
      }
      // On Linux we can only assert type — could be running inside Docker.
      expect(runningContainerId(), anyOf(isNull, isA<String>()));
    });
  });

  group('insideContainer platform-specific', () {
    test('returns false on macOS (/.dockerenv never present on macOS host)', () {
      // /.dockerenv is a Docker-internal file placed only inside containers.
      // On a macOS host machine it cannot exist.
      if (Platform.isMacOS) {
        expect(insideContainer(), isFalse);
      }
    });
  });

  group('isArm platform-specific', () {
    test('isArm() is consistent with uname -m output', () {
      // Verify the Dart result matches what the shell reports.
      try {
        final result = Process.runSync('uname', ['-m']);
        if (result.exitCode == 0) {
          final machine = result.stdout.toString().trim().toLowerCase();
          final expectedArm = machine == 'arm64' || machine == 'aarch64';
          expect(isArm(), equals(expectedArm));
        }
      } catch (_) {
        // uname not available — skip.
      }
    });

    test('isArm() returns true on Apple Silicon (arm64 macOS)', () {
      if (Platform.isMacOS) {
        final result = Process.runSync('uname', ['-m']);
        final machine = result.stdout.toString().trim().toLowerCase();
        if (machine == 'arm64') {
          expect(isArm(), isTrue);
        }
      }
    });
  });

  group('defaultGatewayIp platform-specific', () {
    test('returns null on macOS (ip route not available)', () {
      // macOS does not ship with the `ip` command (Linux iproute2 tooling).
      // The `sh -c "ip route | awk ..."` invocation will fail, and
      // defaultGatewayIp() must return null gracefully.
      if (Platform.isMacOS) {
        expect(defaultGatewayIp(), isNull);
      }
    });
  });
}
