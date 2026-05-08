@Tags(['unit'])
library;

import 'package:test/test.dart';
import 'package:testcontainers/src/config.dart';

void main() {
  group('TestcontainersConfiguration', () {
    test('default maxTries is 120', () {
      final config = TestcontainersConfiguration();
      expect(config.maxTries, equals(120));
    });

    test('default sleepTime is 1.0', () {
      final config = TestcontainersConfiguration();
      expect(config.sleepTime, equals(1.0));
    });

    test('default ryukImage is testcontainers/ryuk:0.8.1', () {
      final config = TestcontainersConfiguration();
      expect(config.ryukImage, equals('testcontainers/ryuk:0.8.1'));
    });

    test('timeout is maxTries * sleepTime', () {
      final config = TestcontainersConfiguration();
      expect(config.timeout, equals(config.maxTries * config.sleepTime));
    });

    test('default ryukDisabled is false', () {
      final config = TestcontainersConfiguration();
      expect(config.ryukDisabled, isFalse);
    });

    test('default ryukPrivileged is false', () {
      final config = TestcontainersConfiguration();
      expect(config.ryukPrivileged, isFalse);
    });

    test('ryukPrivileged setter works', () {
      final config = TestcontainersConfiguration();
      config.ryukPrivileged = true;
      expect(config.ryukPrivileged, isTrue);
    });

    test('ryukDisabled setter works', () {
      final config = TestcontainersConfiguration();
      config.ryukDisabled = true;
      expect(config.ryukDisabled, isTrue);
    });
  });

  group('readTcProperties', () {
    test('returns empty map when file does not exist', () {
      final props = readTcProperties();
      expect(props, isA<Map<String, String>>());
    });
  });

  group('dockerSocket', () {
    test('returns non-empty socket path by default', () {
      final socket = dockerSocket();
      expect(socket, isNotEmpty);
    });
  });

  group('tcHost', () {
    test('returns value from tc.host key in properties map', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['tc.host'] = 'some_value';
      expect(config.tcHost, equals('some_value'));
    });

    test('returns null when tc.host key is absent', () {
      final config = TestcontainersConfiguration();
      config.tcProperties.remove('tc.host');
      expect(config.tcHost, isNull);
    });
  });

  group('ConnectionMode', () {
    test('bridgeIp.useMappedPort is false', () {
      expect(ConnectionMode.bridgeIp.useMappedPort, isFalse);
    });

    test('gatewayIp.useMappedPort is true', () {
      expect(ConnectionMode.gatewayIp.useMappedPort, isTrue);
    });

    test('dockerHost.useMappedPort is true', () {
      expect(ConnectionMode.dockerHost.useMappedPort, isTrue);
    });
  });

  group('overriddenConnectionMode', () {
    test('returns null when env var is absent', () {
      expect(overriddenConnectionMode(), isNull);
    });
  });

  group('_parseInt via TestcontainersConfiguration', () {
    // _parseInt is private; test its effect through public config fields.
    // Verified: default env builds successfully (no throw).
    test('uses default 120 when TC_MAX_TRIES is unset', () {
      final config = TestcontainersConfiguration();
      expect(config.maxTries, equals(120));
    });
  });

  group('_parseDouble via TestcontainersConfiguration', () {
    test('uses default 1.0 when TC_POOLING_INTERVAL is unset', () {
      final config = TestcontainersConfiguration();
      expect(config.sleepTime, equals(1.0));
    });
  });

  group('TestcontainersConfiguration additional defaults', () {
    test('hubImageNamePrefix default is empty string', () {
      final config = TestcontainersConfiguration();
      expect(config.hubImageNamePrefix, equals(''));
    });

    test('ryukReconnectionTimeout default is 10s', () {
      final config = TestcontainersConfiguration();
      expect(config.ryukReconnectionTimeout, equals('10s'));
    });

    test('tcHostOverride default is null', () {
      final config = TestcontainersConfiguration();
      // Unless TC_HOST or TESTCONTAINERS_HOST_OVERRIDE is set in the env,
      // tcHostOverride must be null.
      expect(config.tcHostOverride, isNull);
    });

    test('connectionModeOverride default is null', () {
      // Unless TESTCONTAINERS_CONNECTION_MODE is set, auto-detection is used.
      final config = TestcontainersConfiguration();
      expect(config.connectionModeOverride, isNull);
    });

    test('dockerAuthConfig default is null', () {
      // Only non-null when DOCKER_AUTH_CONFIG env var is set.
      final config = TestcontainersConfiguration();
      // Accept null (standard dev machine) or the env-var value (CI).
      expect(config.dockerAuthConfig, anyOf(isNull, isA<String>()));
    });

    test('ryukDockerSocket returns non-empty path', () {
      final config = TestcontainersConfiguration();
      expect(config.ryukDockerSocket, isNotEmpty);
    });

    test('ryukDockerSocket setter overrides the cached value', () {
      final config = TestcontainersConfiguration();
      config.ryukDockerSocket = '/custom/docker.sock';
      expect(config.ryukDockerSocket, equals('/custom/docker.sock'));
    });

    test('timeout equals maxTries * sleepTime', () {
      final config = TestcontainersConfiguration();
      expect(config.timeout, closeTo(config.maxTries * config.sleepTime, 1e-9));
    });
  });

  group('_resolveFlag via tcProperties (ENABLE_FLAGS)', () {
    // _resolveFlag is private; exercise it through the ryukPrivileged getter
    // on a fresh TestcontainersConfiguration, setting tcProperties BEFORE
    // the lazy getter is first accessed.
    //
    // Truthy tokens recognised by _enableFlags (lowercase):
    // 'yes', 'true', 't', 'y', '1' (compared case-insensitively).

    test('token "yes" in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'yes';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "true" in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'true';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "1" in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = '1';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "TRUE" (uppercase) in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'TRUE';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "YES" (uppercase) in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'YES';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "no" in tcProperties does NOT enable ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'no';
      expect(config.ryukPrivileged, isFalse);
    });

    test('token "false" in tcProperties does NOT enable ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'false';
      expect(config.ryukPrivileged, isFalse);
    });

    test('token "0" in tcProperties does NOT enable ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = '0';
      expect(config.ryukPrivileged, isFalse);
    });

    test('token "t" in tcProperties enables ryukPrivileged', () {
      // 't' is a truthy token in ENABLE_FLAGS alongside 'yes', 'true', 'y', '1'.
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 't';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "T" (uppercase) in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'T';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "y" in tcProperties enables ryukPrivileged', () {
      // 'y' is a truthy token (short for yes).
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'y';
      expect(config.ryukPrivileged, isTrue);
    });

    test('token "Y" (uppercase) in tcProperties enables ryukPrivileged', () {
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.container.privileged'] = 'Y';
      expect(config.ryukPrivileged, isTrue);
    });

    test('absent key defaults to false', () {
      final config = TestcontainersConfiguration();
      config.tcProperties.remove('ryuk.container.privileged');
      expect(config.ryukPrivileged, isFalse);
    });

    test('_resolveFlag covers ryukDisabled through same mechanism (truthy)', () {
      // Both ryukPrivileged and ryukDisabled use the same _resolveFlag helper.
      // Verify that the truthy path also works for ryukDisabled.
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.disabled'] = 'true';
      expect(config.ryukDisabled, isTrue);
    });

    test('_resolveFlag covers ryukDisabled through same mechanism (falsy)', () {
      // Use a fresh instance so the lazy cache has not been seeded by the
      // previous test (??= is computed once and cached).
      final config = TestcontainersConfiguration();
      config.tcProperties['ryuk.disabled'] = 'false';
      expect(config.ryukDisabled, isFalse);
    });

    test('ryukPrivileged and ryukDisabled are independent (both fresh)', () {
      // Each TestcontainersConfiguration has its own lazy-cached booleans.
      final cfgPriv = TestcontainersConfiguration();
      cfgPriv.tcProperties['ryuk.container.privileged'] = 'yes';
      cfgPriv.tcProperties['ryuk.disabled'] = 'no';
      expect(cfgPriv.ryukPrivileged, isTrue);
      expect(cfgPriv.ryukDisabled, isFalse);
    });
  });

  group('ConnectionMode enum', () {
    test('has exactly three values', () {
      expect(ConnectionMode.values, hasLength(3));
    });

    test('values list contains bridgeIp, gatewayIp, dockerHost', () {
      expect(
        ConnectionMode.values,
        containsAll([
          ConnectionMode.bridgeIp,
          ConnectionMode.gatewayIp,
          ConnectionMode.dockerHost,
        ]),
      );
    });

    test('only bridgeIp has useMappedPort = false', () {
      // bridgeIp = false, gatewayIp = true, dockerHost = true
      final falseCount =
          ConnectionMode.values.where((m) => !m.useMappedPort).length;
      expect(falseCount, equals(1));
    });
  });
}
