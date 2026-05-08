/// Docker network lifecycle management.
///
/// [Network] creates and removes a user-defined Docker bridge network. Containers
/// can be placed on the same [Network] so they can communicate by service name
/// without publishing ports to the host.
library;

import 'package:uuid/uuid.dart';

import 'docker_client.dart';

/// A Docker user-defined network managed by testcontainers-dart.
///
/// Networks are created lazily via [create] and removed via [remove]. The
/// static [use] helper combines both operations with a try/finally guarantee,
/// matching the context-manager pattern used in testcontainers-python.
///
/// Example:
/// ```dart
/// await Network.use((network) async {
///   final db = DockerContainer('postgres:16')
///     ..withNetwork(network)
///     ..withNetworkAliases(['db']);
///   final app = DockerContainer('myapp:latest')
///     ..withNetwork(network);
///   // db is reachable from app at hostname 'db'
///   await DockerContainer.use(db, (_) async {
///     await DockerContainer.use(app, (c) async { ... });
///   });
/// });
/// ```
class Network {
  /// The unique name assigned to this network.
  ///
  /// Generated as a random UUID v4 to avoid collisions across concurrent test
  /// runs. The same name is used as the Docker network name.
  final String name;

  String? _networkId;
  final DockerClient _dockerClient;

  /// Creates a [Network] with a randomly generated [name].
  ///
  /// An optional [dockerClient] can be injected for testing; the default
  /// instance reads connection settings from the environment.
  Network({DockerClient? dockerClient})
      : name = const Uuid().v4(),
        _dockerClient = dockerClient ?? DockerClient();

  /// The Docker-assigned network ID, or `null` before [create] is called.
  String? get id => _networkId;

  /// Creates the Docker network and returns `this`.
  ///
  /// Must be called before passing the network to any container. Stores the
  /// Docker-assigned [id] for use in subsequent [connect] and [remove] calls.
  Future<Network> create() async {
    _networkId = await _dockerClient.createNetwork(name);
    return this;
  }

  /// Removes the Docker network.
  ///
  /// Safe to call even if [create] was never called — does nothing in that
  /// case.
  Future<void> remove() async {
    final id = _networkId;
    if (id != null) {
      await _dockerClient.removeNetwork(id);
    }
  }

  /// Attaches [containerId] to this network.
  ///
  /// Optional [networkAliases] are DNS names through which other containers
  /// on the same network can reach [containerId].
  ///
  /// Throws [StateError] if [create] has not been called yet.
  Future<void> connect(
    String containerId, {
    List<String>? networkAliases,
  }) async {
    final networkId = _networkId;
    if (networkId == null) {
      throw StateError(
        'Network must be created before connecting a container. '
        'Call create() first.',
      );
    }
    await _dockerClient.connectNetwork(
      networkId,
      containerId,
      aliases: networkAliases,
    );
  }

  /// Creates a network, runs [fn] with it, and removes the network afterwards.
  ///
  /// The network is removed even if [fn] throws. This is the recommended way
  /// to use a [Network] in a test to ensure cleanup:
  ///
  /// ```dart
  /// await Network.use((net) async {
  ///   // attach containers and run test assertions
  /// });
  /// ```
  static Future<T> use<T>(Future<T> Function(Network) fn) async {
    final network = Network();
    await network.create();
    try {
      return await fn(network);
    } finally {
      await network.remove();
    }
  }
}
