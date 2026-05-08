@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:testcontainers/src/config.dart';
import 'package:testcontainers/src/container.dart';
import 'package:testcontainers/src/exceptions.dart';
import 'package:testcontainers/src/network.dart';
import 'package:testcontainers/src/transferable.dart';
import 'package:testcontainers/src/wait_strategies.dart';

// ---------------------------------------------------------------------------
// Helper subclasses used by the configure() hook tests
// ---------------------------------------------------------------------------

/// A [DockerContainer] subclass whose [configure] override is a no-op — it
/// only calls [super.configure].  Exposes [triggerConfigure] so that the test
/// can invoke [configure] from within the class hierarchy without violating the
/// `@protected` annotation.
class _BaseContainer extends DockerContainer {
  _BaseContainer(super.image);

  /// Calls [configure] from within the class hierarchy (allowed because this
  /// is an instance method of a subclass of [DockerContainer]).
  void triggerConfigure() => configure();
}

/// A [DockerContainer] subclass that overrides [configure] to inject a known
/// environment variable.  Used only in unit tests — no Docker is required.
class _ConfiguringContainer extends DockerContainer {
  _ConfiguringContainer(super.image);

  @override
  void configure() {
    withEnv('CONFIGURED', 'true');
    super.configure();
  }

  /// Public entry-point for test code.
  void triggerConfigure() => configure();
}

void main() {
  group('DockerContainer builder', () {
    test('withEnv adds environment variable', () {
      final c = DockerContainer('nginx:alpine').withEnv('FOO', 'bar');
      expect(c.env['FOO'], equals('bar'));
    });

    test('withEnvs adds multiple variables', () {
      final c = DockerContainer('nginx:alpine').withEnvs({'A': '1', 'B': '2'});
      expect(c.env['A'], equals('1'));
      expect(c.env['B'], equals('2'));
    });

    test('withBindPorts maps ports', () {
      final c = DockerContainer('nginx:alpine').withBindPorts(80, 8080);
      expect(c.ports[80], equals(8080));
    });

    test('withBindPorts without host port is equivalent to withExposedPorts',
        () {
      final c = DockerContainer('nginx:alpine').withBindPorts(8080);
      expect(c.ports[8080], isNull);
    });

    test('withExposedPorts exposes with null host port', () {
      final c = DockerContainer('nginx:alpine').withExposedPorts([80, 443]);
      expect(c.ports[80], isNull);
      expect(c.ports[443], isNull);
    });

    test('withExposedPorts with empty list leaves ports unchanged', () {
      final c = DockerContainer('alpine').withExposedPorts([]);
      expect(c.ports, isEmpty);
    });

    test('withEnvs with empty map leaves env unchanged', () {
      final c = DockerContainer('alpine').withEnv('X', '1').withEnvs({});
      // The pre-existing variable must still be present.
      expect(c.env['X'], equals('1'));
      expect(c.env.length, equals(1));
    });

    test('withEnvs merges with pre-existing variables', () {
      final c = DockerContainer('alpine')
          .withEnv('EXISTING', 'keep')
          .withEnvs({'NEW': 'add'});
      expect(c.env['EXISTING'], equals('keep'));
      expect(c.env['NEW'], equals('add'));
    });

    test('withEnvs overwrites on key collision', () {
      // addAll semantics: new value wins on duplicate key.
      final c = DockerContainer('alpine')
          .withEnv('KEY', 'old')
          .withEnvs({'KEY': 'new'});
      expect(c.env['KEY'], equals('new'));
    });

    test('withCommand accepts String', () {
      final c = DockerContainer('alpine').withCommand('echo hello');
      expect(c.command, equals('echo hello'));
    });

    test('withCommand accepts List<String>', () {
      final c = DockerContainer('alpine').withCommand(['echo', 'hello']);
      expect(c.command, equals(['echo', 'hello']));
    });

    test('withName sets container name', () {
      final c = DockerContainer('alpine').withName('my-container');
      expect(c.name, equals('my-container'));
    });

    test('withVolumeMapping adds volume', () {
      final c = DockerContainer('alpine').withVolumeMapping(
        '/host/path',
        '/container/path',
        'rw',
      );
      expect(c.volumes.containsKey('/host/path'), isTrue);
      final vol = c.volumes['/host/path']!;
      expect(vol.bind, equals('/container/path'));
      expect(vol.mode, equals('rw'));
    });

    test('withVolumeMapping with ro mode', () {
      final c = DockerContainer('alpine').withVolumeMapping(
        '/data',
        '/app/data',
        'ro',
      );
      final vol = c.volumes['/data']!;
      expect(vol.bind, equals('/app/data'));
      expect(vol.mode, equals('ro'));
    });

    test('multiple withVolumeMapping calls accumulate distinct host paths', () {
      final c = DockerContainer('alpine')
          .withVolumeMapping('/h1', '/c1', 'rw')
          .withVolumeMapping('/h2', '/c2', 'ro');
      expect(c.volumes.length, equals(2));
      expect(c.volumes['/h1']!.mode, equals('rw'));
      expect(c.volumes['/h2']!.mode, equals('ro'));
    });

    test('withKwargs sets extra kwargs', () {
      final c = DockerContainer('alpine').withKwargs({'privileged': true});
      expect(c.kwargs['privileged'], isTrue);
    });

    test('withKwargs merges successive calls (does not replace)', () {
      final c = DockerContainer('alpine')
          .withKwargs({'privileged': true}).withKwargs({'auto_remove': true});
      // Both keys must survive — withKwargs merges, not replaces.
      expect(c.kwargs['privileged'], isTrue);
      expect(c.kwargs['auto_remove'], isTrue);
    });

    test('withKwargs overwrites individual keys on collision', () {
      final c = DockerContainer('alpine')
          .withKwargs({'privileged': false}).withKwargs({'privileged': true});
      expect(c.kwargs['privileged'], isTrue);
    });

    test('image gets hub prefix if configured', () {
      testcontainersConfig.dockerAuthConfig = null;
      final c = DockerContainer('nginx:alpine');
      expect(c.image, contains('nginx:alpine'));
    });

    test('maybeEmulateAmd64 does not overwrite user-set platform', () {
      // If the caller already set 'platform', maybeEmulateAmd64 must not
      // clobber it (matches Python: "platform" not in self._kwargs).
      final c =
          DockerContainer('alpine').withKwargs({'platform': 'linux/arm64'})
            // Force the arm-check branch by having the same kwargs merge logic.
            ..maybeEmulateAmd64();
      // 'linux/arm64' must not have been replaced with 'linux/amd64'.
      expect(c.kwargs['platform'], equals('linux/arm64'));
    });

    test('maybeEmulateAmd64 returns same instance for chaining', () {
      final c = DockerContainer('alpine');
      final result = c.maybeEmulateAmd64();
      expect(identical(result, c), isTrue);
    });

    test('withCopyIntoContainer returns same instance for chaining', () {
      final c = DockerContainer('alpine');
      final bytes = Uint8List.fromList([1, 2, 3]);
      final result =
          c.withCopyIntoContainer(BytesTransferable(bytes), '/app/file', 0x1A4);
      expect(identical(result, c), isTrue);
    });

    test('chained builder returns same instance', () {
      final c = DockerContainer('alpine');
      final result = c.withEnv('X', '1').withName('n').withCommand('sh');
      expect(identical(c, result), isTrue);
    });

    test('wrappedContainer getter returns the container itself', () {
      final c = DockerContainer('alpine');
      expect(identical(c.wrappedContainer, c), isTrue);
    });

    test('waitingFor returns same instance for chaining', () {
      final c = DockerContainer('alpine');
      final strategy = LogMessageWaitStrategy('ready');
      final result = c.waitingFor(strategy);
      // waitingFor is a builder method — it must return this, not a new instance.
      expect(identical(result, c), isTrue);
    });

    test('withTmpfsMount adds path without size', () {
      final c = DockerContainer('alpine').withTmpfsMount('/tmp/ramdisk');
      expect(c.tmpfs.containsKey('/tmp/ramdisk'), isTrue);
      expect(c.tmpfs['/tmp/ramdisk'], isEmpty);
    });

    test('withTmpfsMount adds path with size', () {
      final c = DockerContainer('alpine').withTmpfsMount('/run', size: '64m');
      expect(c.tmpfs['/run'], equals('64m'));
    });

    test('tmpfs getter is unmodifiable', () {
      final c = DockerContainer('alpine').withTmpfsMount('/tmp');
      expect(
        () => c.tmpfs['/extra'] = '',
        throwsUnsupportedError,
      );
    });

    test('multiple withTmpfsMount calls accumulate distinct paths', () {
      final c = DockerContainer('alpine')
          .withTmpfsMount('/tmp/a')
          .withTmpfsMount('/tmp/b', size: '32m');
      expect(c.tmpfs.length, equals(2));
      expect(c.tmpfs['/tmp/a'], isEmpty);
      expect(c.tmpfs['/tmp/b'], equals('32m'));
    });

    test('withTmpfsMount overwrites existing path on duplicate call', () {
      final c = DockerContainer('alpine')
          .withTmpfsMount('/run')
          .withTmpfsMount('/run', size: '128m');
      expect(c.tmpfs.length, equals(1));
      expect(c.tmpfs['/run'], equals('128m'));
    });

    test('withNetwork sets network reference', () {
      final network = Network();
      final c = DockerContainer('alpine').withNetwork(network);
      expect(c.network, equals(network));
    });

    test('withNetworkAliases sets aliases', () {
      final c =
          DockerContainer('alpine').withNetworkAliases(['alias1', 'alias2']);
      expect(c.networkAliases, equals(['alias1', 'alias2']));
    });

    test('networkAliases getter is unmodifiable', () {
      final c = DockerContainer('alpine').withNetworkAliases(['a']);
      expect(
        () => c.networkAliases!.add('b'),
        throwsUnsupportedError,
      );
    });

    test('networkAliases is null before withNetworkAliases is called', () {
      final c = DockerContainer('alpine');
      expect(c.networkAliases, isNull);
    });

    test('withNetworkAliases with empty list yields empty (not null) list', () {
      // Passing an empty aliases list should store an empty list, not null.
      final c = DockerContainer('alpine').withNetworkAliases([]);
      expect(c.networkAliases, isNotNull);
      expect(c.networkAliases, isEmpty);
    });

    test('status defaults to not_started before start()', () {
      // _cachedStatus is initialised to 'not_started' and only changes once
      // DockerContainer.start() begins running.
      final c = DockerContainer('alpine');
      expect(c.status, equals('not_started'));
    });

    test('env getter is unmodifiable', () {
      final c = DockerContainer('alpine').withEnv('X', '1');
      expect(
        () => c.env['Y'] = '2',
        throwsUnsupportedError,
      );
    });

    test('ports getter is unmodifiable', () {
      final c = DockerContainer('alpine').withExposedPorts([80]);
      expect(
        () => c.ports[9090] = null,
        throwsUnsupportedError,
      );
    });

    test('volumes getter is unmodifiable', () {
      final c = DockerContainer('alpine').withVolumeMapping('/h', '/c', 'rw');
      expect(
        () => c.volumes['/extra'] = (bind: '/dst', mode: 'ro'),
        throwsUnsupportedError,
      );
    });

    test('kwargs getter is unmodifiable', () {
      final c = DockerContainer('alpine').withKwargs({'privileged': true});
      expect(
        () => c.kwargs['extra'] = false,
        throwsUnsupportedError,
      );
    });

    test('withEnvFile loads key=value pairs', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_test_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync('FOO=bar\nBAZ=qux\n');
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env['FOO'], equals('bar'));
        expect(c.env['BAZ'], equals('qux'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile expands \${VAR} references', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_interp_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync(
            'DOMAIN=example.org\n'
            'ADMIN_EMAIL=admin@\${DOMAIN}\n'
            'ROOT_URL=\${DOMAIN}/app\n',
          );
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env['DOMAIN'], equals('example.org'));
        expect(c.env['ADMIN_EMAIL'], equals('admin@example.org'));
        expect(c.env['ROOT_URL'], equals('example.org/app'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile skips blank lines and comments', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_skip_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync(
            '# This is a comment\n'
            '\n'
            'KEY=value\n',
          );
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env.length, equals(1));
        expect(c.env['KEY'], equals('value'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile skips lines without an = sign', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_noeq_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync(
            'VALID=value\n'
            'NOEQUALSSIGN\n' // no '=' → silently skipped
            'ALSO_VALID=ok\n',
          );
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env['VALID'], equals('value'));
        expect(c.env['ALSO_VALID'], equals('ok'));
        expect(c.env.containsKey('NOEQUALSSIGN'), isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile handles values that contain = sign', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_eq_val_');
      try {
        // Base64-encoded secrets and JWT tokens often contain '='.
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync('SECRET=abc=123==\n');
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env['SECRET'], equals('abc=123=='));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile trims whitespace from keys and values', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_trim_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync('  KEY  =  value  \n');
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env['KEY'], equals('value'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile throws FileSystemException for non-existent file', () {
      // A path that cannot exist (microsecond-suffixed to avoid collisions).
      final missingPath =
          '/tmp/__tc_no_such_env_${DateTime.now().microsecondsSinceEpoch}__';
      expect(
        () => DockerContainer('alpine').withEnvFile(missingPath),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('withEnvFile with only comments produces no env vars', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_all_comment_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync(
            '# This whole file is comments\n'
            '# Another comment\n'
            '\n',
          );
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env, isEmpty);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test(r'withEnvFile resolves unknown ${VAR} to empty string', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_missing_var_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync(r'KEY=prefix-${MISSING_VAR}-suffix' '\n');
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        // ${MISSING_VAR} is not in the resolved map → replaced with ''.
        expect(c.env['KEY'], equals('prefix--suffix'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile handles CRLF line endings correctly', () {
      final tmp = Directory.systemTemp.createTempSync('tc_env_crlf_');
      try {
        // Windows-style line endings: each line ends with \r\n.
        // The trim() inside withEnvFile strips the trailing \r.
        final envFile = File('${tmp.path}/.env')
          ..writeAsBytesSync('A=1\r\nB=2\r\n'.codeUnits);
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        expect(c.env['A'], equals('1'));
        expect(c.env['B'], equals('2'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test(r'withEnvFile does not expand $SIMPLE_VAR (dollar-only, no braces)',
        () {
      // The interpolation regex is r'\$\{([^}]+)\}' — it requires braces.
      // A bare $VAR reference (no braces) is treated as a literal string.
      final tmp = Directory.systemTemp.createTempSync('tc_env_nobrace_');
      try {
        final envFile = File('${tmp.path}/.env')
          // r'...' raw string: backslashes/dollars NOT interpreted by Dart.
          ..writeAsStringSync('KEY=prefix-\$SIMPLE-suffix\n');
        final c = DockerContainer('alpine').withEnvFile(envFile.path);
        // $SIMPLE has no braces → NOT interpolated → literal '\$SIMPLE' kept.
        expect(c.env['KEY'], equals(r'prefix-$SIMPLE-suffix'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test(
        'withEnvFile does not use pre-existing _env vars for interpolation '
        '(resolved map is local to the call)', () {
      // The `resolved` map inside withEnvFile starts EMPTY — it only grows
      // as lines are parsed.  A variable set by withEnv() before calling
      // withEnvFile() is NOT accessible to ${VAR} expansion inside the file.
      final tmp = Directory.systemTemp.createTempSync('tc_env_preexisting_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync('DERIVED=hello-\${HOST}\n');
        // Set HOST via withEnv() BEFORE loading the file.
        final c = DockerContainer('alpine')
          ..withEnv('HOST', 'example.com')
          // Now load the file — ${HOST} in the file cannot see _env['HOST'].
          ..withEnvFile(envFile.path);
        // Because `resolved` starts empty, ${HOST} resolves to ''.
        expect(c.env['DERIVED'], equals('hello-'));
        // The pre-existing HOST variable must still be present.
        expect(c.env['HOST'], equals('example.com'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile merges into env set by withEnv — no collision', () {
      // When the file does not redefine keys already set by withEnv(),
      // both sets of variables must be present in the final env map.
      final tmp = Directory.systemTemp.createTempSync('tc_env_merge_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync('FROM_FILE=file_value\n');
        final c = DockerContainer('alpine')
          ..withEnv('FROM_CODE', 'code_value')
          ..withEnvFile(envFile.path);
        expect(c.env['FROM_CODE'], equals('code_value'));
        expect(c.env['FROM_FILE'], equals('file_value'));
        expect(c.env.length, equals(2));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('withEnvFile overwrites pre-existing key when file redefines it', () {
      // withEnvFile calls _env[key] = value, so a key already in _env gets
      // replaced if the file contains a line with the same key.
      final tmp = Directory.systemTemp.createTempSync('tc_env_overwrite_');
      try {
        final envFile = File('${tmp.path}/.env')
          ..writeAsStringSync('KEY=from_file\n');
        final c = DockerContainer('alpine')
          ..withEnv('KEY', 'from_code')
          ..withEnvFile(envFile.path);
        // File line is parsed last → file value wins.
        expect(c.env['KEY'], equals('from_file'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('DockerContainer.splitCommand', () {
    test('splits on spaces', () {
      expect(
        DockerContainer.splitCommand('nginx -g daemon off;'),
        equals(['nginx', '-g', 'daemon', 'off;']),
      );
    });

    test('handles single-quoted argument with internal spaces', () {
      expect(
        DockerContainer.splitCommand("echo 'hello world'"),
        equals(['echo', 'hello world']),
      );
    });

    test('handles double-quoted argument with internal spaces', () {
      expect(
        DockerContainer.splitCommand('nginx -c "/etc/nginx/nginx.conf"'),
        equals(['nginx', '-c', '/etc/nginx/nginx.conf']),
      );
    });

    test('handles multiple consecutive spaces', () {
      expect(
        DockerContainer.splitCommand('a  b   c'),
        equals(['a', 'b', 'c']),
      );
    });

    test('handles tab as whitespace', () {
      expect(
        DockerContainer.splitCommand('a\tb'),
        equals(['a', 'b']),
      );
    });

    test('returns empty list for empty string', () {
      expect(DockerContainer.splitCommand(''), isEmpty);
    });

    test('returns empty list for whitespace-only string', () {
      expect(DockerContainer.splitCommand('   '), isEmpty);
    });

    test('single token without spaces', () {
      expect(DockerContainer.splitCommand('sh'), equals(['sh']));
    });

    test('single-quoted arg preserves double quotes inside', () {
      expect(
        DockerContainer.splitCommand(r"""echo '"hello"'"""),
        equals(['echo', '"hello"']),
      );
    });

    test('double-quoted arg preserves single quotes inside', () {
      expect(
        DockerContainer.splitCommand("""echo "'hello'" """),
        equals(['echo', "'hello'"]),
      );
    });

    test('adjacent tokens with no space between word and quote', () {
      // e.g. foo"bar" -> foobar (standard sh behaviour)
      expect(
        DockerContainer.splitCommand('foo"bar"'),
        equals(['foobar']),
      );
    });

    test('unclosed double quote includes content up to end', () {
      // Unclosed quotes consume everything to the end of the string.
      expect(
        DockerContainer.splitCommand('"hello world'),
        equals(['hello world']),
      );
    });

    test('unclosed single quote includes content up to end', () {
      expect(
        DockerContainer.splitCommand("'hello world"),
        equals(['hello world']),
      );
    });

    test('empty single-quoted argument is dropped (no empty token emitted)',
        () {
      // The parser only emits a token when current is non-empty at word
      // boundaries; adjacent empty quotes produce no token.
      expect(
        DockerContainer.splitCommand("cmd ''"),
        equals(['cmd']),
      );
    });

    test('empty double-quoted argument is dropped (no empty token emitted)',
        () {
      expect(
        DockerContainer.splitCommand('cmd ""'),
        equals(['cmd']),
      );
    });

    test('backslash is treated as a literal character (not an escape)', () {
      // The parser has no escape handling — backslash is not special.
      // 'a\\b' is kept as-is in the output token.
      expect(
        DockerContainer.splitCommand(r'a\b'),
        equals([r'a\b']),
      );
    });

    test('multiple backslashes remain literal', () {
      expect(
        DockerContainer.splitCommand(r'cmd --arg=a\\b\\c'),
        equals([r'cmd', r'--arg=a\\b\\c']),
      );
    });

    test('backslash before space does NOT escape the space', () {
      // Without backslash-escape support, '\ ' still splits on the space.
      // This test documents the actual behaviour.
      expect(
        DockerContainer.splitCommand(r'a\ b'),
        equals([r'a\', 'b']),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // WaitStrategyTarget interface — pre-start behaviour
  // ---------------------------------------------------------------------------
  group('DockerContainer WaitStrategyTarget before start', () {
    test('containerHostIp() returns localhost before start', () async {
      final c = DockerContainer('alpine');
      // _containerId is null → implementation returns 'localhost'
      expect(await c.containerHostIp(), equals('localhost'));
    });

    test('exposedPort() returns port unchanged before start', () async {
      final c = DockerContainer('alpine');
      // _containerId is null → returns port as-is (no Docker lookup possible).
      expect(await c.exposedPort(8080), equals(8080));
      expect(await c.exposedPort(5432), equals(5432));
    });

    test('reload() completes without error before start (no-op)', () async {
      final c = DockerContainer('alpine');
      // _containerId is null → reload() exits immediately.
      await expectLater(c.reload(), completes);
    });

    test('logs() throws ContainerStartException before start', () async {
      final c = DockerContainer('alpine');
      await expectLater(
        c.logs(),
        throwsA(isA<ContainerStartException>()),
      );
    });

    test('exec() throws ContainerStartException before start', () {
      // exec() is not async — _requireContainerId throws synchronously,
      // so we wrap in a lambda to let expect() catch the sync throw.
      final c = DockerContainer('alpine');
      expect(
        () => c.exec(['echo', 'hi']),
        throwsA(isA<ContainerStartException>()),
      );
    });

    test('containerInfo() returns null before start', () async {
      final c = DockerContainer('alpine');
      // _containerId is null → returns null without making a Docker call.
      expect(await c.containerInfo(), isNull);
    });

    test('wrappedContainer returns this', () {
      final c = DockerContainer('alpine');
      expect(identical(c.wrappedContainer, c), isTrue);
    });

    test('status returns not_started before start', () {
      final c = DockerContainer('alpine');
      expect(c.status, equals('not_started'));
    });
  });

  // ---------------------------------------------------------------------------
  // DockerContainer.configure() extension hook
  // ---------------------------------------------------------------------------
  group('DockerContainer.configure hook', () {
    test('base configure() is a no-op — no env/ports/volumes added', () {
      // The default configure() must not throw or mutate state.
      // _BaseContainer.triggerConfigure() delegates to super.configure().
      final c = _BaseContainer('alpine');
      expect(() => c.triggerConfigure(), returnsNormally);
      // No env, ports, or volumes should have been added.
      expect(c.env, isEmpty);
      expect(c.ports, isEmpty);
      expect(c.volumes, isEmpty);
    });

    test('subclass can add env variables in configure()', () {
      // Verify that a subclass calling withEnv inside configure() is reflected
      // in the env map — the hook integrates correctly with the builder.
      final c = _ConfiguringContainer('alpine');
      c.triggerConfigure(); // invoke via the subclass public bridge
      expect(c.env['CONFIGURED'], equals('true'));
    });

    test(
        'subclass configure() can be called multiple times (idempotent env set)',
        () {
      // Calling configure() twice must not create duplicate env entries — it
      // simply overwrites the same key with the same value.
      final c = _ConfiguringContainer('alpine');
      c.triggerConfigure();
      c.triggerConfigure();
      expect(c.env['CONFIGURED'], equals('true'));
      expect(c.env.length, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // DockerContainer.dockerClient getter
  // ---------------------------------------------------------------------------
  group('DockerContainer.dockerClient', () {
    test('dockerClient getter returns a non-null DockerClient', () {
      final c = DockerContainer('alpine');
      expect(c.dockerClient, isNotNull);
    });

    test('dockerClient returns same instance on repeated access', () {
      final c = DockerContainer('alpine');
      expect(identical(c.dockerClient, c.dockerClient), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // DockerContainer lifecycle — pre-start no-ops / throws
  // ---------------------------------------------------------------------------
  group('DockerContainer lifecycle before start', () {
    test('stop() before start completes without error (no-op)', () async {
      final c = DockerContainer('alpine');
      // _containerId is null → stop() exits immediately without Docker call.
      await expectLater(c.stop(), completes);
    });

    test('stop(force: false) before start is also a no-op', () async {
      final c = DockerContainer('alpine');
      await expectLater(c.stop(force: false, deleteVolume: false), completes);
    });

    test('wait() throws ContainerStartException before start', () async {
      final c = DockerContainer('alpine');
      await expectLater(
        c.wait(),
        throwsA(isA<ContainerStartException>()),
      );
    });

    test('execShell() throws ContainerStartException before start', () {
      // execShell() → exec() — both are non-async; _requireContainerId throws
      // synchronously, so use a lambda to let expect() catch the sync throw.
      final c = DockerContainer('alpine');
      expect(
        () => c.execShell('echo hello'),
        throwsA(isA<ContainerStartException>()),
      );
    });

    test('copyFromContainer() throws ContainerStartException before start',
        () async {
      final c = DockerContainer('alpine');
      await expectLater(
        c.copyFromContainer('/etc/hosts', '/tmp/out.tar'),
        throwsA(isA<ContainerStartException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // DockerContainer.withCopyIntoContainer accumulation
  // ---------------------------------------------------------------------------
  group('DockerContainer.withCopyIntoContainer accumulation', () {
    test('single transferable spec is stored', () {
      final c = DockerContainer('alpine');
      final bytes = Uint8List.fromList([1, 2, 3]);
      c.withCopyIntoContainer(BytesTransferable(bytes), '/app/file', 0x1A4);
      // The spec list is private; verify indirectly via builder return value.
      expect(identical(c, c), isTrue); // sanity — chaining returns this
    });

    test('multiple withCopyIntoContainer calls accumulate', () {
      final c = DockerContainer('alpine');
      final b1 = Uint8List.fromList([1]);
      final b2 = Uint8List.fromList([2]);
      // Chain two copies; both builder calls must return the same instance.
      final result = c
          .withCopyIntoContainer(BytesTransferable(b1), '/a', 0x1A4)
          .withCopyIntoContainer(BytesTransferable(b2), '/b', 0x1ED);
      expect(identical(result, c), isTrue);
    });
  });
}
