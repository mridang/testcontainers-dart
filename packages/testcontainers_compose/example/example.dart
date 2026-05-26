import 'package:testcontainers_compose/testcontainers_compose.dart';

void main() async {
  await DockerCompose.use(
    DockerCompose(context: 'example/fixtures'),
    (compose) async {
      final web = compose.container('web');
      final port = await web.exposedPort(8080);
      // make HTTP requests to localhost:port
      assert(port > 0);
    },
  );
}
