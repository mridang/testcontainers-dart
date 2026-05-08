import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:testcontainers_core/src/config.dart';
import 'package:testcontainers_core/src/wait_strategies.dart';
import 'package:testcontainers_compose/testcontainers_compose.dart';

final _fixtures = '${Directory.current.path}/test/compose_fixtures';

String fixture(String name) => '$_fixtures/$name';

Future<(int, String)> fetchUrl(String url) async {
  final response = await http.get(Uri.parse(url));
  return (response.statusCode, response.body);
}

void main() {
  group('unit tests', () {
    test(
      'composeNoFileName',
      () {
        final basic = DockerCompose(context: fixture('basic'));
        expect(basic.composeFileName, isNull);
      },
      tags: ['unit'],
    );

    test(
      'composeStrFileName',
      () {
        final basic = DockerCompose(
          context: fixture('basic'),
          composeFileName: ['docker-compose.yaml'],
        );
        expect(basic.composeFileName, equals(['docker-compose.yaml']));
      },
      tags: ['unit'],
    );

    test(
      'composeListFileName',
      () {
        final basic = DockerCompose(
          context: fixture('basic'),
          composeFileName: ['a.yaml', 'b.yaml'],
        );
        expect(basic.composeFileName, equals(['a.yaml', 'b.yaml']));
      },
      tags: ['unit'],
    );

    test(
      'containerInfoNoneWhenNoDockerCompose',
      () async {
        final container = ComposeContainer();
        final info = await container.containerInfo();
        expect(info, isNull);
      },
      tags: ['unit'],
    );

    test(
      'normalizeRewritesLocalUrlForSshDockerHost_sshReplacesWildcard',
      () {
        final savedDockerHost = Platform.environment['DOCKER_HOST'];
        try {
          _withEnv({'DOCKER_HOST': 'ssh://user@10.0.0.5'}, () {
            final model = const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 9999,
              protocol: 'tcp',
            );
            final result = model.normalize();
            expect(result.url, equals('10.0.0.5'));
            expect(result.publishedPort, equals(9999));
          });
        } finally {
          if (savedDockerHost != null) {
            _withEnv({'DOCKER_HOST': savedDockerHost}, () {});
          }
        }
      },
      tags: ['unit'],
      // Platform.environment is read-only in Dart; subprocess env changes
      // do not affect the running Dart process.
      skip: 'Dart cannot mutate Platform.environment at runtime',
    );

    test(
      'normalizeRewritesLocalUrlForSshDockerHost_sshReplacesLoopback',
      () {
        _withEnv({'DOCKER_HOST': 'ssh://user@10.0.0.5'}, () {
          final model = const PublishedPortModel(
            url: '127.0.0.1',
            targetPort: 80,
            publishedPort: 9999,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('10.0.0.5'));
          expect(result.publishedPort, equals(9999));
        });
      },
      tags: ['unit'],
      skip: 'Dart cannot mutate Platform.environment at runtime',
    );

    test(
      'normalizeRewritesLocalUrlForSshDockerHost_sshReplacesIpv6Any',
      () {
        _withEnv({'DOCKER_HOST': 'ssh://user@10.0.0.5'}, () {
          final model = const PublishedPortModel(
            url: '::',
            targetPort: 80,
            publishedPort: 9999,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('10.0.0.5'));
          expect(result.publishedPort, equals(9999));
        });
      },
      tags: ['unit'],
      skip: 'Dart cannot mutate Platform.environment at runtime',
    );

    test(
      'normalizeRewritesLocalUrlForSshDockerHost_nonSshKeepsOriginal',
      () {
        _withEnv({'DOCKER_HOST': 'tcp://localhost:2375'}, () {
          final model = const PublishedPortModel(
            url: '0.0.0.0',
            targetPort: 80,
            publishedPort: 9999,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('0.0.0.0'));
          expect(result.publishedPort, equals(9999));
        });
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // PublishedPortModel unit tests
    // -------------------------------------------------------------------------
    test(
      'publishedPortModel fromJson parses all fields',
      () {
        final json = {
          'URL': '0.0.0.0',
          'TargetPort': 80,
          'PublishedPort': 32768,
          'Protocol': 'tcp',
        };
        final model = PublishedPortModel.fromJson(json);
        expect(model.url, equals('0.0.0.0'));
        expect(model.targetPort, equals(80));
        expect(model.publishedPort, equals(32768));
        expect(model.protocol, equals('tcp'));
      },
      tags: ['unit'],
    );

    test(
      'publishedPortModel fromJson tolerates null fields',
      () {
        final model = PublishedPortModel.fromJson({});
        expect(model.url, isNull);
        expect(model.targetPort, isNull);
        expect(model.publishedPort, isNull);
        expect(model.protocol, isNull);
      },
      tags: ['unit'],
    );

    test(
      'publishedPortModel normalize returns same instance when url unchanged',
      () {
        const model = PublishedPortModel(
          url: '192.168.1.1',
          targetPort: 80,
          publishedPort: 9999,
          protocol: 'tcp',
        );
        // No SSH host, not 0.0.0.0 on Windows — should return identical object.
        expect(identical(model.normalize(), model), isTrue);
      },
      tags: ['unit'],
    );

    test(
      'publishedPortModel normalize returns same instance for null url',
      () {
        const model = PublishedPortModel(targetPort: 80, publishedPort: 9999);
        expect(identical(model.normalize(), model), isTrue);
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // ComposeContainer.publisher filter tests
    // -------------------------------------------------------------------------
    test(
      'composeContainer publisher finds by targetPort',
      () {
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 443,
              publishedPort: 32769,
              protocol: 'tcp',
            ),
          ],
        );
        final pub = container.publisher(byPort: 80);
        expect(pub.publishedPort, equals(32768));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer publisher throws NoSuchPortExposed for missing port',
      () {
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        expect(
          () => container.publisher(byPort: 9999),
          throwsA(isA<NoSuchPortExposed>()),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeContainer publisher throws NoSuchPortExposed when ambiguous',
      () {
        // Two IPv4 publishers on the same port (e.g. two interfaces).
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '127.0.0.1',
              targetPort: 80,
              publishedPort: 32769,
              protocol: 'tcp',
            ),
          ],
        );
        expect(
          () => container.publisher(byPort: 80),
          throwsA(isA<NoSuchPortExposed>()),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeContainer publisher filters by byHost',
      () {
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '127.0.0.1',
              targetPort: 80,
              publishedPort: 32769,
              protocol: 'tcp',
            ),
          ],
        );
        final pub = container.publisher(byPort: 80, byHost: '127.0.0.1');
        expect(pub.publishedPort, equals(32769));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer status returns state or unknown',
      () {
        expect(
          ComposeContainer(state: 'running').status,
          equals('running'),
        );
        expect(ComposeContainer().status, equals('unknown'));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer publishers list is unmodifiable',
      () {
        final container = ComposeContainer(
          publishers: [
            const PublishedPortModel(url: '0.0.0.0', targetPort: 80),
          ],
        );
        expect(
          () => container.publishers.add(const PublishedPortModel()),
          throwsUnsupportedError,
        );
      },
      tags: ['unit'],
    );

    test(
      'composeContainer logs throws StateError without dockerCompose reference',
      () async {
        final container = ComposeContainer(service: 'web');
        await expectLater(
          container.logs(),
          throwsA(isA<StateError>()),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeContainer exec throws StateError without dockerCompose reference',
      () async {
        final container = ComposeContainer(service: 'web');
        await expectLater(
          container.exec(['echo', 'hi']),
          throwsA(isA<StateError>()),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeContainer exec throws StateError when service name is null',
      () async {
        // service=null, no _dockerCompose reference either —
        // the StateError for missing compose fires first.
        final container = ComposeContainer();
        await expectLater(
          container.exec(['echo']),
          throwsA(isA<StateError>()),
        );
      },
      tags: ['unit'],
    );

    test(
      'ipVersion ipv4 filter excludes IPv6 addresses',
      () {
        // IPv6 url contains ':' — should be filtered out when preferring IPv4.
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '::',
              targetPort: 80,
              publishedPort: 32770,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        // Default is IPv4; should return the 0.0.0.0 publisher.
        final pub = container.publisher(byPort: 80);
        expect(pub.publishedPort, equals(32768));
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // DockerCompose.composeCommandProperty unit tests
    // -------------------------------------------------------------------------
    test(
      'composeCommandProperty defaults to docker compose',
      () {
        final dc = DockerCompose(context: '/tmp');
        expect(dc.composeCommandProperty, equals(['docker', 'compose']));
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty uses dockerCommandPath when set',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          dockerCommandPath: '/usr/local/bin/docker',
        );
        expect(
          dc.composeCommandProperty,
          equals(['/usr/local/bin/docker', 'compose']),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty includes -f for each composeFileName',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          composeFileName: ['a.yaml', 'b.yaml'],
        );
        expect(
          dc.composeCommandProperty,
          equals(['docker', 'compose', '-f', 'a.yaml', '-f', 'b.yaml']),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty includes --profile for each profile',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          profiles: ['debug', 'metrics'],
        );
        expect(
          dc.composeCommandProperty,
          equals([
            'docker',
            'compose',
            '--profile',
            'debug',
            '--profile',
            'metrics',
          ]),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty includes --env-file for each envFile',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          envFile: ['.env', '.env.local'],
        );
        expect(
          dc.composeCommandProperty,
          equals([
            'docker',
            'compose',
            '--env-file',
            '.env',
            '--env-file',
            '.env.local',
          ]),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty is unmodifiable',
      () {
        final dc = DockerCompose(context: '/tmp');
        expect(
          () => dc.composeCommandProperty.add('extra'),
          throwsUnsupportedError,
        );
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose waitingFor stores strategies map',
      () {
        final dc = DockerCompose(context: '/tmp');
        final strategy = LogMessageWaitStrategy('ready');
        final result = dc.waitingFor({'web': strategy});
        // Fluent — returns same instance.
        expect(identical(result, dc), isTrue);
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // ComposeContainer WaitStrategyTarget interface unit tests
    // -------------------------------------------------------------------------
    test(
      'composeContainer containerHostIp returns 127.0.0.1',
      () async {
        final container = ComposeContainer(service: 'web');
        final ip = await container.containerHostIp();
        expect(ip, equals('127.0.0.1'));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer exposedPort returns port unchanged',
      () async {
        final container = ComposeContainer(service: 'web');
        // ComposeContainer exposes the container port directly; host-port is
        // obtained via publisher().publishedPort, not through exposedPort().
        expect(await container.exposedPort(8080), equals(8080));
        expect(await container.exposedPort(5432), equals(5432));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer reload completes without error',
      () async {
        final container = ComposeContainer(service: 'web');
        // reload() is a no-op for Compose containers.
        await expectLater(container.reload(), completes);
      },
      tags: ['unit'],
    );

    test(
      'composeContainer wrappedContainer returns this',
      () {
        final container = ComposeContainer(service: 'web');
        expect(identical(container.wrappedContainer, container), isTrue);
      },
      tags: ['unit'],
    );

    test(
      'containerInfo returns null when id is set but no dockerCompose reference',
      () async {
        // id present but _dockerCompose is null — must return null, not throw.
        final container = ComposeContainer(id: 'abc123', service: 'web');
        final info = await container.containerInfo();
        expect(info, isNull);
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // ComposeContainer.fromJson unit tests
    // -------------------------------------------------------------------------
    test(
      'composeContainer fromJson parses all scalar fields',
      () {
        final json = {
          'ID': 'deadbeef',
          'Name': 'myproject_web_1',
          'Command': 'nginx -g daemon off;',
          'Project': 'myproject',
          'Service': 'web',
          'State': 'running',
          'Health': 'healthy',
          'ExitCode': 0,
          'Publishers': <dynamic>[],
        };
        final c = ComposeContainer.fromJson(json);
        expect(c.id, equals('deadbeef'));
        expect(c.name, equals('myproject_web_1'));
        expect(c.command, equals('nginx -g daemon off;'));
        expect(c.project, equals('myproject'));
        expect(c.service, equals('web'));
        expect(c.state, equals('running'));
        expect(c.health, equals('healthy'));
        expect(c.exitCode, equals(0));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer fromJson parses publishers',
      () {
        final json = {
          'ID': 'abc',
          'Service': 'web',
          'State': 'running',
          'Publishers': [
            {
              'URL': '0.0.0.0',
              'TargetPort': 80,
              'PublishedPort': 32768,
              'Protocol': 'tcp',
            },
          ],
        };
        final c = ComposeContainer.fromJson(json);
        expect(c.publishers, hasLength(1));
        expect(c.publishers.first.targetPort, equals(80));
        expect(c.publishers.first.publishedPort, equals(32768));
      },
      tags: ['unit'],
    );

    test(
      'composeContainer fromJson tolerates missing fields',
      () {
        final c = ComposeContainer.fromJson({});
        expect(c.id, isNull);
        expect(c.service, isNull);
        expect(c.publishers, isEmpty);
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // DockerCompose constructor defaults unit tests
    // -------------------------------------------------------------------------
    test(
      'DockerCompose constructor defaults',
      () {
        final dc = DockerCompose(context: '/tmp');
        expect(dc.pull, isFalse);
        expect(dc.build, isFalse);
        expect(dc.wait, isTrue);
        expect(dc.keepVolumes, isFalse);
        expect(dc.quietPull, isFalse);
        expect(dc.quietBuild, isFalse);
        expect(dc.composeFileName, isNull);
        expect(dc.envFile, isNull);
        expect(dc.services, isNull);
        expect(dc.profiles, isNull);
        expect(dc.dockerCommandPath, isNull);
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose services list is unmodifiable',
      () {
        final dc = DockerCompose(context: '/tmp', services: ['web', 'db']);
        expect(
          () => dc.services!.add('cache'),
          throwsUnsupportedError,
        );
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose profiles list is unmodifiable',
      () {
        final dc = DockerCompose(context: '/tmp', profiles: ['debug']);
        expect(
          () => dc.profiles!.add('extra'),
          throwsUnsupportedError,
        );
      },
      tags: ['unit'],
    );

    test(
      'IpVersion enum has ipv4 and ipv6 values',
      () {
        expect(IpVersion.values, containsAll([IpVersion.ipv4, IpVersion.ipv6]));
      },
      tags: ['unit'],
    );

    test(
      'ipVersion ipv6 filter selects IPv6 address over IPv4',
      () {
        // IPv6 url contains ':' — should be selected when preferring IPv6.
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '::',
              targetPort: 80,
              publishedPort: 32770,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        final pub = container.publisher(
          byPort: 80,
          preferIpVersion: IpVersion.ipv6,
        );
        expect(pub.publishedPort, equals(32770));
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose envFile list is unmodifiable',
      () {
        final dc = DockerCompose(context: '/tmp', envFile: ['.env']);
        expect(
          () => dc.envFile!.add('.env.extra'),
          throwsUnsupportedError,
        );
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose composeFileName list is unmodifiable',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          composeFileName: ['docker-compose.yaml'],
        );
        expect(
          () => dc.composeFileName!.add('override.yaml'),
          throwsUnsupportedError,
        );
      },
      tags: ['unit'],
    );

    test(
      'publisher with null url is treated as IPv4 when preferring IPv4',
      () {
        // _matchesProtocol: (null?.contains(':') ?? false) == false → true
        // A publisher with no URL is included when IPv4 is preferred.
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        final pub = container.publisher(byPort: 80);
        expect(pub.publishedPort, equals(32768));
      },
      tags: ['unit'],
    );

    test(
      'publisher with null url is excluded when preferring IPv6',
      () {
        // _matchesProtocol: false == true → false → excluded.
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        expect(
          () => container.publisher(
            byPort: 80,
            preferIpVersion: IpVersion.ipv6,
          ),
          throwsA(isA<NoSuchPortExposed>()),
        );
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // PublishedPortModel.fromJson unit tests
    // -------------------------------------------------------------------------
    test(
      'PublishedPortModel fromJson parses all fields',
      () {
        final model = PublishedPortModel.fromJson({
          'URL': '0.0.0.0',
          'TargetPort': 8080,
          'PublishedPort': 32768,
          'Protocol': 'tcp',
        });
        expect(model.url, equals('0.0.0.0'));
        expect(model.targetPort, equals(8080));
        expect(model.publishedPort, equals(32768));
        expect(model.protocol, equals('tcp'));
      },
      tags: ['unit'],
    );

    test(
      'PublishedPortModel fromJson tolerates missing fields',
      () {
        final model = PublishedPortModel.fromJson({});
        expect(model.url, isNull);
        expect(model.targetPort, isNull);
        expect(model.publishedPort, isNull);
        expect(model.protocol, isNull);
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // PublishedPortModel.normalize unit tests (non-SSH, non-Windows paths)
    // -------------------------------------------------------------------------
    test(
      'normalize returns same instance when url is already a non-loopback address',
      () {
        // '10.1.2.3' is not a loopback and not 0.0.0.0 → no rewrite → same obj.
        const model = PublishedPortModel(
          url: '10.1.2.3',
          targetPort: 80,
          publishedPort: 32768,
          protocol: 'tcp',
        );
        // No SSH host configured and not Windows → identical reference.
        final result = model.normalize();
        // When no rewrite is needed, normalize() returns `this` to avoid
        // allocating a new object.
        expect(result.url, equals('10.1.2.3'));
        expect(result.publishedPort, equals(32768));
      },
      tags: ['unit'],
    );

    test(
      'normalize on non-SSH host returns 0.0.0.0 unchanged on Linux/macOS',
      () {
        // Without an SSH Docker host, 0.0.0.0 should remain as-is on non-Windows.
        if (!Platform.isWindows) {
          const model = PublishedPortModel(
            url: '0.0.0.0',
            targetPort: 80,
            publishedPort: 32768,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('0.0.0.0'));
        }
      },
      tags: ['unit'],
    );

    test(
      'PublishedPortModel const constructor stores all fields',
      () {
        const model = PublishedPortModel(
          url: '127.0.0.1',
          targetPort: 443,
          publishedPort: 8443,
          protocol: 'udp',
        );
        expect(model.url, equals('127.0.0.1'));
        expect(model.targetPort, equals(443));
        expect(model.publishedPort, equals(8443));
        expect(model.protocol, equals('udp'));
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // Additional coverage for publisher() edge cases
    // -------------------------------------------------------------------------
    test(
      'publisher() throws NoSuchPortExposed when byHost does not match any '
      'publisher',
      () {
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        // byHost='192.168.1.1' is not present — no match → NoSuchPortExposed.
        expect(
          () => container.publisher(byPort: 80, byHost: '192.168.1.1'),
          throwsA(isA<NoSuchPortExposed>()),
        );
      },
      tags: ['unit'],
    );

    test(
      'publisher() error message contains the service name',
      () {
        final container = ComposeContainer(
          service: 'database',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 5432,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
          ],
        );
        expect(
          () => container.publisher(byPort: 9999),
          throwsA(
            isA<NoSuchPortExposed>().having(
              (e) => e.message,
              'message',
              contains('database'),
            ),
          ),
        );
      },
      tags: ['unit'],
    );

    test(
      'publisher() ambiguous error message contains the match count',
      () {
        // Three IPv4 publishers on the same target port → ambiguous.
        final container = ComposeContainer(
          service: 'web',
          publishers: [
            const PublishedPortModel(
              url: '0.0.0.0',
              targetPort: 80,
              publishedPort: 32768,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '127.0.0.1',
              targetPort: 80,
              publishedPort: 32769,
              protocol: 'tcp',
            ),
            const PublishedPortModel(
              url: '10.0.0.1',
              targetPort: 80,
              publishedPort: 32770,
              protocol: 'tcp',
            ),
          ],
        );
        expect(
          () => container.publisher(byPort: 80),
          throwsA(
            isA<NoSuchPortExposed>().having(
              (e) => e.message,
              'message',
              contains('3'),
            ),
          ),
        );
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty returns identical list on repeated access '
      '(late final caching)',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          composeFileName: ['a.yaml'],
        );
        // The `late final` field is computed once; subsequent reads must return
        // the exact same List instance.
        expect(
          identical(dc.composeCommandProperty, dc.composeCommandProperty),
          isTrue,
        );
      },
      tags: ['unit'],
    );

    test(
      'composeCommandProperty with all options combines flags in the correct '
      'order: -f before --profile before --env-file',
      () {
        final dc = DockerCompose(
          context: '/tmp',
          composeFileName: ['docker-compose.yaml'],
          profiles: ['debug'],
          envFile: ['.env'],
        );
        expect(
          dc.composeCommandProperty,
          equals([
            'docker',
            'compose',
            '-f',
            'docker-compose.yaml',
            '--profile',
            'debug',
            '--env-file',
            '.env',
          ]),
        );
      },
      tags: ['unit'],
    );

    test(
      'containerInfo() returns null on every call when no dockerCompose '
      'reference is set (no caching of null crashes)',
      () async {
        final container = ComposeContainer(id: 'abc123');
        // First call — returns null.
        expect(await container.containerInfo(), isNull);
        // Second call — must also return null, not throw.
        expect(await container.containerInfo(), isNull);
      },
      tags: ['unit'],
    );

    test(
      'ComposeContainer default constructor leaves all fields null',
      () {
        final container = ComposeContainer();
        expect(container.id, isNull);
        expect(container.name, isNull);
        expect(container.command, isNull);
        expect(container.project, isNull);
        expect(container.service, isNull);
        expect(container.state, isNull);
        expect(container.health, isNull);
        expect(container.exitCode, isNull);
        expect(container.publishers, isEmpty);
      },
      tags: ['unit'],
    );

    test(
      'IpVersion.values has exactly two entries',
      () {
        expect(IpVersion.values, hasLength(2));
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose waitingFor with empty map stores empty map and returns this',
      () {
        final dc = DockerCompose(context: '/tmp');
        final result = dc.waitingFor({});
        expect(identical(result, dc), isTrue);
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // DockerCompose constructor stores context
    // -------------------------------------------------------------------------
    test(
      'DockerCompose stores context correctly',
      () {
        final dc = DockerCompose(context: '/my/project');
        expect(dc.context, equals('/my/project'));
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // DockerCompose constructor makes defensive copies of List parameters
    // -------------------------------------------------------------------------
    test(
      'DockerCompose constructor makes defensive copy of composeFileName',
      () {
        final files = ['a.yaml'];
        final dc = DockerCompose(context: '/tmp', composeFileName: files);
        files.add('b.yaml'); // mutate original after construction
        expect(dc.composeFileName, equals(['a.yaml']));
        expect(dc.composeFileName, hasLength(1));
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose constructor makes defensive copy of services',
      () {
        final svcList = ['web', 'db'];
        final dc = DockerCompose(context: '/tmp', services: svcList);
        svcList.add('cache'); // mutate original
        expect(dc.services, equals(['web', 'db']));
        expect(dc.services, hasLength(2));
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose constructor makes defensive copy of profiles',
      () {
        final profileList = ['debug'];
        final dc = DockerCompose(context: '/tmp', profiles: profileList);
        profileList.add('metrics'); // mutate original
        expect(dc.profiles, equals(['debug']));
      },
      tags: ['unit'],
    );

    test(
      'DockerCompose constructor makes defensive copy of envFile',
      () {
        final envFiles = ['.env'];
        final dc = DockerCompose(context: '/tmp', envFile: envFiles);
        envFiles.add('.env.local'); // mutate original
        expect(dc.envFile, equals(['.env']));
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // PublishedPortModel.normalize SSH host via tcProperties (avoids
    // Platform.environment mutation which is read-only in Dart)
    // -------------------------------------------------------------------------
    test(
      'normalize rewrites localhost URL when SSH tc.host is set',
      () {
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@myhost.example.com';
          const model = PublishedPortModel(
            url: 'localhost',
            targetPort: 80,
            publishedPort: 9999,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('myhost.example.com'));
          expect(result.publishedPort, equals(9999));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );

    test(
      'normalize rewrites ::1 URL when SSH tc.host is set',
      () {
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@myhost.example.com';
          const model = PublishedPortModel(
            url: '::1',
            targetPort: 443,
            publishedPort: 8443,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('myhost.example.com'));
          expect(result.publishedPort, equals(8443));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );

    test(
      'normalize returns a new PublishedPortModel instance when URL is rewritten',
      () {
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@myhost.example.com';
          const model = PublishedPortModel(
            url: '0.0.0.0',
            targetPort: 80,
            publishedPort: 9999,
            protocol: 'tcp',
          );
          final result = model.normalize();
          // URL was rewritten → must be a different object.
          expect(identical(result, model), isFalse);
          expect(result.url, equals('myhost.example.com'));
          // Other fields are preserved.
          expect(result.targetPort, equals(80));
          expect(result.publishedPort, equals(9999));
          expect(result.protocol, equals('tcp'));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );

    test(
      'normalize rewrites 127.0.0.1 URL when SSH tc.host is set',
      () {
        // Covers the `url == '127.0.0.1'` branch in normalize() —
        // exercised via tcProperties to avoid read-only Platform.environment.
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@remote.example.com';
          const model = PublishedPortModel(
            url: '127.0.0.1',
            targetPort: 443,
            publishedPort: 8443,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('remote.example.com'));
          expect(result.targetPort, equals(443));
          expect(result.publishedPort, equals(8443));
          expect(result.protocol, equals('tcp'));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );

    test(
      'normalize rewrites :: URL when SSH tc.host is set',
      () {
        // Covers the `url == '::'` branch in normalize() — the IPv6 any-address.
        // Exercised via tcProperties to avoid read-only Platform.environment.
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@remote.example.com';
          const model = PublishedPortModel(
            url: '::',
            targetPort: 80,
            publishedPort: 32769,
            protocol: 'tcp',
          );
          final result = model.normalize();
          expect(result.url, equals('remote.example.com'));
          expect(result.targetPort, equals(80));
          expect(result.publishedPort, equals(32769));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );

    test(
      'normalize does not rewrite non-loopback URL when SSH tc.host is set',
      () {
        // A public IP like '203.0.113.5' is not in the loopback list →
        // normalize() must return the original model unchanged.
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@remote.example.com';
          const model = PublishedPortModel(
            url: '203.0.113.5',
            targetPort: 80,
            publishedPort: 32770,
            protocol: 'tcp',
          );
          final result = model.normalize();
          // URL is not in the loopback set → no rewrite → same instance.
          expect(identical(result, model), isTrue);
          expect(result.url, equals('203.0.113.5'));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );

    // -------------------------------------------------------------------------
    // ComposeContainer.fromJson publisher normalisation
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // DockerCompose.waitFor unit tests — use a real local HTTP server so we
    // exercise the full retry / success path without Docker.
    // -------------------------------------------------------------------------
    test(
      'waitFor returns this when the URL responds immediately with 200',
      () async {
        final server = await HttpServer.bind('127.0.0.1', 0);
        final port = server.port;
        unawaited(
          server.forEach((req) {
            req.response.statusCode = 200;
            req.response.close();
          }),
        );
        try {
          final dc = DockerCompose(context: '/tmp');
          final result = await dc.waitFor('http://127.0.0.1:$port/');
          // waitFor returns `this` for chaining.
          expect(identical(result, dc), isTrue);
        } finally {
          await server.close();
        }
      },
      tags: ['unit'],
    );

    test(
      'waitFor succeeds for a 201 Created response',
      () async {
        final server = await HttpServer.bind('127.0.0.1', 0);
        final port = server.port;
        unawaited(
          server.forEach((req) {
            req.response.statusCode = 201;
            req.response.close();
          }),
        );
        try {
          final dc = DockerCompose(context: '/tmp');
          final result = await dc.waitFor('http://127.0.0.1:$port/');
          expect(identical(result, dc), isTrue);
        } finally {
          await server.close();
        }
      },
      tags: ['unit'],
    );

    test(
      'ComposeContainer fromJson normalizes publishers automatically',
      () {
        // Set up an SSH tc.host so normalize() rewrites 0.0.0.0 → the host.
        final savedTcHost = testcontainersConfig.tcProperties['tc.host'];
        try {
          testcontainersConfig.tcProperties['tc.host'] =
              'ssh://user@ssh-host.example.com';
          final json = {
            'ID': 'abc',
            'Service': 'web',
            'State': 'running',
            'Publishers': [
              {
                'URL': '0.0.0.0',
                'TargetPort': 80,
                'PublishedPort': 32768,
                'Protocol': 'tcp',
              },
            ],
          };
          final c = ComposeContainer.fromJson(json);
          // fromJson calls normalize() on each publisher.
          expect(c.publishers.first.url, equals('ssh-host.example.com'));
        } finally {
          if (savedTcHost == null) {
            testcontainersConfig.tcProperties.remove('tc.host');
          } else {
            testcontainersConfig.tcProperties['tc.host'] = savedTcHost;
          }
        }
      },
      tags: ['unit'],
    );
  });

  group('integration tests', () {
    test(
      'composeStop',
      () {
        final basic = DockerCompose(context: fixture('basic'));
        basic.stop();
      },
      tags: ['integration'],
    );

    test(
      'composeStartStop',
      () async {
        final basic = DockerCompose(context: fixture('basic'));
        await basic.start();
        basic.stop();
      },
      tags: ['integration'],
    );

    test(
      'startStopMultiple',
      () async {
        final dcA = DockerCompose(
          context: fixture('basic_multiple'),
          services: ['alpine1'],
        );
        final dcB = DockerCompose(
          context: fixture('basic_multiple'),
          services: ['alpine2'],
        );

        await dcA.start();
        dcA.container('alpine1');
        dcB.container('alpine1');

        expect(dcA.containers(), hasLength(1));
        expect(dcB.containers(), hasLength(1));

        expect(
          () => dcA.container('alpine2'),
          throwsA(isA<ContainerIsNotRunning>()),
        );
        expect(
          () => dcB.container('alpine2'),
          throwsA(isA<ContainerIsNotRunning>()),
        );

        await dcB.start();
        dcA.container('alpine2');
        dcB.container('alpine2');
        expect(dcA.containers(), hasLength(2));
        expect(dcB.containers(), hasLength(2));

        dcA.stop();
        dcA.container('alpine2');
        dcB.container('alpine2');
        expect(dcA.containers(), hasLength(1));
        expect(dcB.containers(), hasLength(1));

        expect(
          () => dcA.container('alpine1'),
          throwsA(isA<ContainerIsNotRunning>()),
        );
        expect(
          () => dcB.container('alpine1'),
          throwsA(isA<ContainerIsNotRunning>()),
        );

        dcB.stop();
        expect(dcA.containers(), hasLength(0));
        expect(dcB.containers(), hasLength(0));
      },
      tags: ['integration'],
    );

    test(
      'compose',
      () async {
        final basic = DockerCompose(context: fixture('basic'));
        try {
          var containers = basic.containers(includeAll: true);
          expect(containers, hasLength(0));

          await basic.start();
          containers = basic.containers(includeAll: true);
          expect(containers, hasLength(1));
          containers = basic.containers();
          expect(containers, hasLength(1));

          final fromAll = containers.first;
          expect(fromAll.state, equals('running'));
          expect(fromAll.service, equals('alpine'));

          final byName = basic.container('alpine');
          expect(byName.name, equals(fromAll.name));
          expect(byName.service, equals(fromAll.service));
          expect(byName.state, equals(fromAll.state));
          expect(byName.id, equals(fromAll.id));
          expect(byName.exitCode, equals(0));

          basic.stop(down: false);

          expect(
            () => basic.container('alpine'),
            throwsA(isA<ContainerIsNotRunning>()),
          );

          final stopped = basic.container('alpine', true);
          expect(stopped.state, equals('exited'));
        } finally {
          basic.stop();
        }
      },
      tags: ['integration'],
    );

    test(
      'composeLogs',
      () async {
        final basic = DockerCompose(context: fixture('basic'));
        await DockerCompose.use(basic, (dc) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          final (stdout, stderr) = dc.logs();
          final container = dc.container();

          expect(stderr, isEmpty);
          expect(stdout, isNotEmpty);

          final lines = stdout.split(RegExp(r'\r?\n'));
          expect(lines.length, greaterThan(5));

          for (final line in lines.skip(1)) {
            if (line.isEmpty) continue;
            final firstCol = line.split('|').first;
            expect(firstCol, contains(container.service));
          }
        });
      },
      tags: ['integration'],
    );

    test(
      'composeVolumes',
      () async {
        const fileInVolume = '/var/lib/example/data/hello';
        var volumes = DockerCompose(
          context: fixture('basic_volume'),
          keepVolumes: true,
        );

        await DockerCompose.use(volumes, (dc) async {
          final (_, _, exitcode) = dc.execInContainer(
            ['/bin/sh', '-c', 'echo hello > $fileInVolume'],
            serviceName: 'alpine',
          );
          expect(exitcode, equals(0));
        });

        volumes = DockerCompose(
          context: fixture('basic_volume'),
        );

        await DockerCompose.use(volumes, (dc) async {
          final (stdout, _, exitcode) = dc.execInContainer(
            ['cat', fileInVolume],
            serviceName: 'alpine',
          );
          expect(exitcode, equals(0));
          expect(stdout, contains('hello'));
        });

        final volNoKeep = DockerCompose(
          context: fixture('basic_volume'),
        );

        await DockerCompose.use(volNoKeep, (dc) async {
          expect(
            () => dc
                .execInContainer(['cat', fileInVolume], serviceName: 'alpine'),
            throwsA(isA<ProcessException>()),
          );
        });
      },
      tags: ['integration'],
    );

    test(
      'composePorts',
      () async {
        final single = DockerCompose(context: fixture('port_single'));
        await DockerCompose.use(single, (dc) async {
          final (host, port) = dc.serviceHostAndPort();
          final endpoint = 'http://$host:$port';
          await dc.waitFor(endpoint);
          final (code, response) = await fetchUrl(endpoint);
          expect(code, equals(200));
          expect(response, contains('<h1>'));
        });
      },
      tags: ['integration'],
    );

    test(
      'composeMultipleContainersAndPorts',
      () async {
        final multiple = DockerCompose(context: fixture('port_multiple'));
        await DockerCompose.use(multiple, (dc) async {
          expect(
            () => dc.container(),
            throwsA(isA<ContainerIsNotRunning>()),
          );

          dc.container('alpine');
          dc.container('alpine2');

          final a2p = dc.servicePort(serviceName: 'alpine2');
          expect(a2p, isNotNull);
          expect(a2p, greaterThan(0));

          expect(
            () => dc.servicePort(serviceName: 'alpine'),
            throwsA(isA<NoSuchPortExposed>()),
          );
          expect(
            () => dc.container('alpine').publisher(byHost: 'example.com'),
            throwsA(isA<NoSuchPortExposed>()),
          );
          expect(
            () => dc.container('alpine').publisher(byHost: 'localhost'),
            throwsA(isA<NoSuchPortExposed>()),
          );

          try {
            dc.container('alpine').publisher(
                  byPort: 81,
                  preferIpVersion: IpVersion.ipv6,
                );
          } catch (_) {}

          final ports = [
            (
              80,
              dc.serviceHost(serviceName: 'alpine', port: 80),
              dc.servicePort(serviceName: 'alpine', port: 80),
            ),
            (
              81,
              dc.serviceHost(serviceName: 'alpine', port: 81),
              dc.servicePort(serviceName: 'alpine', port: 81),
            ),
            (
              82,
              dc.serviceHost(serviceName: 'alpine', port: 82),
              dc.servicePort(serviceName: 'alpine', port: 82),
            ),
          ];

          for (final (target, host, mapped) in ports) {
            expect(mapped, isNotNull, reason: 'mapped port for target $target');
            final url = 'http://$host:$mapped';
            final (code, _) = await fetchUrl(url);

            final expectedCode = {80: 200, 81: 202, 82: 204}[target];
            if (expectedCode == null) continue;
            expect(code, equals(expectedCode), reason: 'response from $url');
          }
        });
      },
      tags: ['integration'],
    );

    test(
      'execInContainer',
      () async {
        final single = DockerCompose(context: fixture('port_single'));
        await DockerCompose.use(single, (dc) async {
          final url = 'http://${dc.serviceHost()}:${dc.servicePort()}';
          await dc.waitFor(url);

          var (code, body) = await fetchUrl(url);
          expect(code, equals(200));
          expect(body, isNot(contains('test_exec_in_container')));

          dc.execInContainer([
            'sh',
            '-c',
            'echo "test_exec_in_container" > /usr/share/nginx/html/index.html',
          ]);

          (code, body) = await fetchUrl(url);
          expect(code, equals(200));
          expect(body, contains('test_exec_in_container'));
        });
      },
      tags: ['integration'],
    );

    test(
      'execInContainerMultiple',
      () async {
        final multiple = DockerCompose(context: fixture('port_multiple'));
        await DockerCompose.use(multiple, (dc) async {
          const sn = 'alpine2';
          final (host, port) = dc.serviceHostAndPort(serviceName: sn);
          final url = 'http://$host:$port';
          await dc.waitFor(url);

          var (code, body) = await fetchUrl(url);
          expect(code, equals(200));
          expect(body, isNot(contains('test_exec_in_container')));

          dc.execInContainer(
            [
              'sh',
              '-c',
              'echo "test_exec_in_container" > /usr/share/nginx/html/index.html',
            ],
            serviceName: sn,
          );

          (code, body) = await fetchUrl(url);
          expect(code, equals(200));
          expect(body, contains('test_exec_in_container'));
        });
      },
      tags: ['integration'],
    );

    final contextFixtures = [
      'basic',
      'basic_multiple',
      'basic_volume',
      'port_single',
      'port_multiple',
      'profile_support',
    ];

    for (final ctx in contextFixtures) {
      test(
        'composeConfig_$ctx',
        () {
          final compose = DockerCompose(context: fixture(ctx));

          final receivedConfig = compose.config();

          expect(receivedConfig, isNotEmpty);
          expect(receivedConfig, isA<Map<String, dynamic>>());
          expect(receivedConfig, contains('services'));
        },
        tags: ['integration'],
      );
    }

    for (final ctx in contextFixtures) {
      test(
        'composeConfigRaw_$ctx',
        () {
          final compose = DockerCompose(context: fixture(ctx));

          final receivedConfig = compose.config(
            pathResolution: false,
            normalize: false,
            interpolate: false,
          );

          expect(receivedConfig, isNotEmpty);
          expect(receivedConfig, isA<Map<String, dynamic>>());
          expect(receivedConfig, contains('services'));
        },
        tags: ['integration'],
      );
    }

    final profileCases = [
      (
        null,
        ['runs-always'],
        ['runs-profile-a', 'runs-profile-b'],
        'default',
      ),
      (
        ['profile-a'],
        ['runs-always', 'runs-profile-a'],
        ['runs-profile-b'],
        'oneAdditionalProfileViaStr',
      ),
      (
        ['profile-a', 'profile-b'],
        ['runs-always', 'runs-profile-a', 'runs-profile-b'],
        <String>[],
        'allProfilesExplicitly',
      ),
    ];

    for (final (profiles, running, notRunning, id) in profileCases) {
      test(
        'composeProfileSupport_$id',
        () async {
          final compose = DockerCompose(
            context: fixture('profile_support'),
            profiles: profiles,
          );
          await DockerCompose.use(compose, (dc) async {
            for (final service in running) {
              expect(dc.container(service), isNotNull);
            }
            for (final service in notRunning) {
              expect(
                () => dc.container(service),
                throwsA(isA<ContainerIsNotRunning>()),
              );
            }
          });
        },
        tags: ['integration'],
      );
    }

    test(
      'containerInfo',
      () async {
        final basic = DockerCompose(context: fixture('basic'));
        await DockerCompose.use(basic, (dc) async {
          final container = dc.container('alpine');
          final info = await container.containerInfo();

          expect(info, isNotNull);
          expect(info!.id, isNotNull);
          expect(info.name, isNotNull);
          expect(info.image, isNotNull);

          expect(info.state, isNotNull);
          expect(info.state!.status, equals('running'));
          expect(info.state!.running, isTrue);
          expect(info.state!.pid, isNotNull);

          expect(info.config, isNotNull);
          expect(info.config!.image, isNotNull);
          expect(info.config!.hostname, isNotNull);

          final networkSettings = info.networkSettings;
          expect(networkSettings, isNotNull);
          expect(networkSettings!.networks, isNotNull);

          final info2 = await container.containerInfo();
          expect(identical(info, info2), isTrue);
        });
      },
      tags: ['integration'],
    );

    test(
      'containerInfoNetworkDetails',
      () async {
        final single = DockerCompose(context: fixture('port_single'));
        await DockerCompose.use(single, (dc) async {
          final container = dc.container();
          final info = await container.containerInfo();
          expect(info, isNotNull);

          final networkSettings = info!.networkSettings;
          expect(networkSettings, isNotNull);

          if (networkSettings!.networks != null &&
              networkSettings.networks!.isNotEmpty) {
            final network = networkSettings.networks!.values.first;
            expect(network.ipAddress, isNotNull);
            expect(network.gateway, isNotNull);
            expect(network.networkID, isNotNull);
          }
        });
      },
      tags: ['integration'],
    );
  });
}

void _withEnv(Map<String, String> env, void Function() fn) {
  final saved = <String, String?>{};
  for (final key in env.keys) {
    saved[key] = Platform.environment[key];
  }

  for (final entry in env.entries) {
    _setEnv(entry.key, entry.value);
  }

  try {
    fn();
  } finally {
    for (final entry in saved.entries) {
      if (entry.value != null) {
        _setEnv(entry.key, entry.value!);
      } else {
        _unsetEnv(entry.key);
      }
    }
  }
}

void _setEnv(String key, String value) {
  Process.runSync('bash', ['-c', 'export $key=$value']);
}

void _unsetEnv(String key) {
  Process.runSync('bash', ['-c', 'unset $key']);
}
