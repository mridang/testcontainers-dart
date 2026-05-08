# testcontainers_compose

Docker Compose support for Testcontainers Dart.

## Usage

```dart
import 'package:testcontainers_compose/testcontainers_compose.dart';
import 'package:http/http.dart' as http;

void main() async {
  final compose = DockerCompose(context: 'test/fixtures');
  await DockerCompose.use(compose, (c) async {
    await c.waitFor('http://localhost:8080');
    final response = await http.get(Uri.parse('http://localhost:8080'));
    assert(response.statusCode == 200);
  });
}
```

## Constructor fields

| Field | Default | Description |
|---|---|---|
| `context` | required | Directory with compose file |
| `composeFileName` | null | File name(s) |
| `pull` | false | Pull images before up |
| `build` | false | Build before up |
| `wait` | true | Use `--wait` flag |
| `keepVolumes` | false | Preserve volumes on stop |
| `envFile` | null | .env file path(s) |
| `services` | null | Specific services |
| `profiles` | null | Compose profiles |

## Structured wait strategies

```dart
import 'package:testcontainers_core/testcontainers.dart';

final compose = DockerCompose(context: 'fixtures/myapp')
  ..waitingFor({
    'web': HttpWaitStrategy(8080).forStatusCode(200),
    'db': LogMessageWaitStrategy('database system is ready'),
  });

await DockerCompose.use(compose, (c) async {
  // all services ready
});
```

## License

Apache 2.0
