import 'package:testcontainers_core/testcontainers_core.dart';

void main() async {
  await DockerContainer.use(
    DockerContainer('redis:7-alpine').withExposedPorts([6379]).waitingFor(
      LogMessageWaitStrategy(r'Ready to accept connections'),
    ),
    (container) async {
      final host = await container.containerHostIp();
      final port = await container.exposedPort(6379);
      // connect to redis on host:port
      assert(host.isNotEmpty);
      assert(port > 0);
    },
  );
}
