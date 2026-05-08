@Tags(['unit'])
library;

import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:testcontainers/src/docker_client.dart';
import 'package:testcontainers/src/image.dart';

class _MockDockerClient extends Mock implements DockerClient {}

void main() {
  group('DockerImage constructor defaults', () {
    test('path is stored', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.path, equals('/tmp/myapp'));
    });

    test('tag is null by default', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.tag, isNull);
    });

    test('tag is stored when supplied', () {
      final img = DockerImage(path: '/tmp/myapp', tag: 'myapp:test');
      expect(img.tag, equals('myapp:test'));
    });

    test('cleanUp defaults to true', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.cleanUp, isTrue);
    });

    test('cleanUp can be set to false', () {
      final img = DockerImage(path: '/tmp/myapp', cleanUp: false);
      expect(img.cleanUp, isFalse);
    });

    test('dockerfilePath is null by default', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.dockerfilePath, isNull);
    });

    test('dockerfilePath is stored when supplied', () {
      final img = DockerImage(path: '/tmp/myapp', dockerfilePath: 'Dockerfile.dev');
      expect(img.dockerfilePath, equals('Dockerfile.dev'));
    });

    test('noCache defaults to false', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.noCache, isFalse);
    });

    test('noCache can be set to true', () {
      final img = DockerImage(path: '/tmp/myapp', noCache: true);
      expect(img.noCache, isTrue);
    });
  });

  group('DockerImage.shortId before build', () {
    test('shortId is empty before build', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.shortId, isEmpty);
    });
  });

  group('DockerImage.logs before build', () {
    test('logs is empty before build', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(img.logs, isEmpty);
    });

    test('logs is unmodifiable before build', () {
      final img = DockerImage(path: '/tmp/myapp');
      expect(
        () => img.logs.add({'stream': 'test'}),
        throwsUnsupportedError,
      );
    });
  });

  group('DockerImage.remove before build', () {
    test('remove completes without error when build was never called', () async {
      // _imageId is null → remove() is a no-op regardless of cleanUp.
      final img = DockerImage(path: '/tmp/myapp');
      await expectLater(img.remove(), completes);
    });

    test('remove with cleanUp=false is also a no-op', () async {
      final img = DockerImage(path: '/tmp/myapp', cleanUp: false);
      await expectLater(img.remove(), completes);
    });
  });

  group('DockerImage.shortId strip and truncate logic', () {
    // We cannot call build() without Docker, but we can verify the logic by
    // constructing instances and reading the documented API contract:
    // shortId strips 'sha256:' and truncates to 12 chars.
    //
    // The implementation reads _imageId directly, which is only set after
    // build(). We verify the pre-build contract and rely on integration tests
    // for the post-build state.

    test('shortId returns empty string for a fresh instance', () {
      // Ensures no side-effects from constructor produce a non-empty shortId.
      expect(DockerImage(path: '.').shortId, isEmpty);
      expect(DockerImage(path: '.', tag: 'img:v1').shortId, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // DockerImage.shortId after build — mock-based tests that exercise the
  // sha256: strip and 12-char truncation logic without a real Docker daemon.
  // ---------------------------------------------------------------------------
  group('DockerImage.shortId after build (mock DockerClient)', () {
    late _MockDockerClient mockClient;

    setUp(() {
      mockClient = _MockDockerClient();
    });

    /// Helper: stub buildImage to return [imageId] and empty logs.
    void stubBuild(String imageId) {
      when(
        () => mockClient.buildImage(
          any(),
          tag: any(named: 'tag'),
          noCache: any(named: 'noCache'),
          dockerfile: any(named: 'dockerfile'),
        ),
      ).thenAnswer((_) async => (imageId, <Map<String, dynamic>>[]));
    }

    test('strips sha256: prefix and truncates to 12 chars', () async {
      // Full sha256 image ID — sha256: stripped, first 12 hex chars kept.
      stubBuild('sha256:abc123def456789012345678901234567890');
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(img.shortId, equals('abc123def456'));
    });

    test('truncates non-sha256 ID to 12 chars', () async {
      stubBuild('abcdef1234567890extra');
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(img.shortId, equals('abcdef123456'));
    });

    test('returns full ID when ID is exactly 12 chars', () async {
      stubBuild('abcdef123456');
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(img.shortId, equals('abcdef123456'));
    });

    test('returns full ID when ID is shorter than 12 chars', () async {
      stubBuild('short');
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(img.shortId, equals('short'));
    });

    test('strips sha256: prefix leaving fewer than 12 chars — returns rest', () async {
      // sha256:abc → strip → abc (3 chars, <12 → return as-is)
      stubBuild('sha256:abc');
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(img.shortId, equals('abc'));
    });

    test('logs is populated after build', () async {
      final fakeLogs = [
        {'stream': 'Step 1/3 : FROM alpine'},
        {'stream': 'Step 2/3 : RUN echo hi'},
      ];
      when(
        () => mockClient.buildImage(
          any(),
          tag: any(named: 'tag'),
          noCache: any(named: 'noCache'),
          dockerfile: any(named: 'dockerfile'),
        ),
      ).thenAnswer((_) async => ('sha256:abc123', fakeLogs));
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(img.logs, hasLength(2));
      expect(img.logs.first['stream'], equals('Step 1/3 : FROM alpine'));
    });

    test('logs is unmodifiable after build', () async {
      when(
        () => mockClient.buildImage(
          any(),
          tag: any(named: 'tag'),
          noCache: any(named: 'noCache'),
          dockerfile: any(named: 'dockerfile'),
        ),
      ).thenAnswer((_) async => ('sha256:abc', [<String, dynamic>{'stream': 'ok'}]));
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      expect(
        () => img.logs.add({'stream': 'extra'}),
        throwsUnsupportedError,
      );
    });

    test('remove is a no-op when cleanUp is false (even after build)', () async {
      // cleanUp=false → remove() must not call removeImage even after build.
      stubBuild('sha256:deadbeef');
      when(
        () => mockClient.removeImage(
          any(),
          force: any(named: 'force'),
          noPrune: any(named: 'noPrune'),
        ),
      ).thenAnswer((_) async {});
      final img = DockerImage(
        path: '/ctx',
        cleanUp: false,
        dockerClient: mockClient,
      );
      await img.build();
      await img.remove();
      // removeImage must NOT have been called.
      verifyNever(
        () => mockClient.removeImage(
          any(),
          force: any(named: 'force'),
          noPrune: any(named: 'noPrune'),
        ),
      );
    });

    test('remove calls removeImage when cleanUp is true', () async {
      const fakeId = 'sha256:deadbeef';
      stubBuild(fakeId);
      when(
        () => mockClient.removeImage(
          any(),
          force: any(named: 'force'),
          noPrune: any(named: 'noPrune'),
        ),
      ).thenAnswer((_) async {});
      // cleanUp defaults to true — no need to specify it explicitly.
      final img = DockerImage(path: '/ctx', dockerClient: mockClient);
      await img.build();
      await img.remove();
      // removeImage must have been called exactly once with the image ID.
      verify(
        () => mockClient.removeImage(
          fakeId,
          force: any(named: 'force'),
          noPrune: any(named: 'noPrune'),
        ),
      ).called(1);
    });
  });
}
