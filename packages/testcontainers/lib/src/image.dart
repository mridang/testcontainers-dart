/// Custom Docker image builder.
///
/// [DockerImage] builds a Docker image from a local build context (a directory
/// containing a `Dockerfile`) and optionally removes the image after use. The
/// static [use] helper combines build and remove with a try/finally guarantee.
library;

import 'docker_client.dart';

/// A Docker image built from a local context directory.
///
/// Use [build] to trigger the Docker daemon to build the image from [path].
/// The resulting image can then be referenced by [DockerContainer] using its
/// [tag] or [shortId].
///
/// Example:
/// ```dart
/// await DockerImage.use(
///   DockerImage(path: './my-service', tag: 'my-service:test'),
///   (image) async {
///     final container = DockerContainer(image.tag!);
///     await DockerContainer.use(container, (c) async {
///       // run tests against c
///     });
///   },
/// );
/// ```
class DockerImage {
  /// The path to the Docker build context directory.
  ///
  /// Must contain a `Dockerfile` (or the file named by [dockerfilePath]).
  final String path;

  /// Optional image tag applied to the built image (e.g. `'myapp:test'`).
  final String? tag;

  /// Whether to remove the image after [use] completes.
  ///
  /// Defaults to `true`. Set to `false` to keep the image in the local image
  /// cache for inspection or reuse.
  final bool cleanUp;

  /// Optional path to the Dockerfile relative to [path].
  ///
  /// When `null`, Docker looks for `Dockerfile` in [path].
  final String? dockerfilePath;

  /// Whether to disable the Docker build cache (`--no-cache`).
  ///
  /// Defaults to `false`.
  final bool noCache;

  final DockerClient _dockerClient;

  String? _imageId;
  List<Map<String, dynamic>> _logs = const [];

  /// Creates a [DockerImage] from the given parameters.
  ///
  /// An optional [dockerClient] can be injected for testing; the default
  /// instance reads connection settings from the environment.
  DockerImage({
    required this.path,
    this.tag,
    this.cleanUp = true,
    this.dockerfilePath,
    this.noCache = false,
    DockerClient? dockerClient,
  }) : _dockerClient = dockerClient ?? DockerClient();

  /// Returns the first 12 characters of the image ID (the "short" form).
  ///
  /// The `sha256:` prefix is stripped before truncating. Returns an empty
  /// string before [build] is called.
  String get shortId {
    final id = _imageId ?? '';
    final stripped = id.startsWith('sha256:') ? id.substring(7) : id;
    return stripped.length > 12 ? stripped.substring(0, 12) : stripped;
  }

  /// Builds the Docker image and returns `this`.
  ///
  /// Sends the contents of [path] as a tar archive to the Docker daemon's
  /// `POST /build` endpoint. The resulting image ID is stored in [shortId].
  ///
  /// Throws `HttpException` if the build fails (non-2xx response from the
  /// Docker daemon).
  Future<DockerImage> build() async {
    final (imageId, logs) = await _dockerClient.buildImage(
      path,
      tag: tag,
      noCache: noCache,
      dockerfile: dockerfilePath,
    );
    _imageId = imageId;
    _logs = List.unmodifiable(logs);
    return this;
  }

  /// Removes the image from the local Docker image cache.
  ///
  /// Has no effect if [cleanUp] is `false` or if [build] was never called.
  ///
  /// Parameters:
  /// - [force] — forces removal even if the image is referenced by stopped
  ///   containers. Defaults to `true`.
  /// - [noPrune] — when `true`, parent images are not removed. Defaults to
  ///   `false`.
  Future<void> remove({bool force = true, bool noPrune = false}) async {
    final imageId = _imageId;
    if (imageId != null && cleanUp) {
      await _dockerClient.removeImage(
        imageId,
        force: force,
        noPrune: noPrune,
      );
    }
  }

  /// The build log as a list of JSON log objects.
  ///
  /// Each element is a map decoded from one line of the streaming build
  /// response. Empty before [build] is called. The returned list is
  /// unmodifiable.
  List<Map<String, dynamic>> get logs => _logs;

  /// Builds [image], runs [fn] with it, and removes it afterwards.
  ///
  /// The image is removed even if [fn] throws. This is the recommended way to
  /// use a custom image in tests:
  ///
  /// ```dart
  /// await DockerImage.use(
  ///   DockerImage(path: './fixtures/nginx', tag: 'test-nginx:latest'),
  ///   (image) async {
  ///     await DockerContainer.use(DockerContainer(image.tag!), (c) async {
  ///       // test against c
  ///     });
  ///   },
  /// );
  /// ```
  static Future<T> use<T>(
    DockerImage image,
    Future<T> Function(DockerImage) fn,
  ) async {
    await image.build();
    try {
      return await fn(image);
    } finally {
      await image.remove();
    }
  }
}
