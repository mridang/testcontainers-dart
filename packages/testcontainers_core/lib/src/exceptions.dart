/// Exception types thrown by testcontainers-dart.
///
/// All exceptions implement [Exception] and carry a human-readable [message]
/// string. They are thrown from [DockerContainer] and [DockerCompose] lifecycle
/// methods when something goes wrong with a container's lifecycle or networking.
library;

import 'package:meta/meta.dart';

/// Thrown when a container cannot be started.
///
/// This typically indicates a problem at the `docker run` / `POST
/// /containers/{id}/start` level — for example an invalid image name, an
/// image that cannot be pulled, a port that is already bound, or insufficient
/// Docker daemon permissions.
///
/// Example:
/// ```dart
/// try {
///   await container.start();
/// } on ContainerStartException catch (e) {
///   print(e.message); // human-readable reason
/// }
/// ```
@immutable
class ContainerStartException implements Exception {
  /// Human-readable description of why the container could not be started.
  final String message;

  /// Creates a [ContainerStartException] with the given [message].
  const ContainerStartException(this.message);

  @override
  String toString() => 'ContainerStartException: $message';
}

/// Thrown when a running container cannot be reached over the network.
///
/// Raised when the host IP address or mapped port of a container cannot be
/// determined, or when the [Reaper] (ryuk) TCP handshake fails after all
/// retry attempts are exhausted.
///
/// Example:
/// ```dart
/// try {
///   await container.start();
/// } on ContainerConnectException catch (e) {
///   print(e.message);
/// }
/// ```
@immutable
class ContainerConnectException implements Exception {
  /// Human-readable description of why the connection could not be established.
  final String message;

  /// Creates a [ContainerConnectException] with the given [message].
  const ContainerConnectException(this.message);

  @override
  String toString() => 'ContainerConnectException: $message';
}

/// Thrown when an operation requires a running container but the container is
/// not (or is no longer) in the `running` state.
///
/// Common triggers include calling `DockerCompose.container` when the
/// requested service has exited, or calling `DockerCompose.container`
/// without a service name when there is not exactly one running container.
///
/// Example:
/// ```dart
/// try {
///   final c = compose.container('web');
/// } on ContainerIsNotRunning catch (e) {
///   print(e.message);
/// }
/// ```
@immutable
class ContainerIsNotRunning implements Exception {
  /// Human-readable description of which container is not running and why.
  final String message;

  /// Creates a [ContainerIsNotRunning] with the given [message].
  const ContainerIsNotRunning(this.message);

  @override
  String toString() => 'ContainerIsNotRunning: $message';
}

/// Thrown when a requested port is not exposed by the container.
///
/// Raised by `ComposeContainer.publisher` when no matching publisher can be
/// found for the requested port, host, or IP-version combination.
///
/// Example:
/// ```dart
/// try {
///   final pub = container.publisher(byPort: 9999);
/// } on NoSuchPortExposed catch (e) {
///   print(e.message);
/// }
/// ```
@immutable
class NoSuchPortExposed implements Exception {
  /// Human-readable description of which port was not found and on which service.
  final String message;

  /// Creates a [NoSuchPortExposed] with the given [message].
  const NoSuchPortExposed(this.message);

  @override
  String toString() => 'NoSuchPortExposed: $message';
}
