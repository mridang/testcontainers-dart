# testcontainers-dart

Dart port of [testcontainers-python](https://github.com/testcontainers/testcontainers-python) — throwaway Docker containers for integration testing.

## Packages

| Package                                                      | Description                                                       |
|--------------------------------------------------------------|-------------------------------------------------------------------|
| [`testcontainers`](packages/testcontainers/)                 | Core library: container lifecycle, wait strategies, Docker client |
| [`testcontainers_compose`](packages/testcontainers_compose/) | Docker Compose support                                            |

## Prerequisites

- Dart SDK ≥ 3.4.0
- Docker (daemon running)
- [devbox](https://www.jetpack.io/devbox/) (optional, for reproducible dev environment)

## Quick Start

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

## Development

```bash
# Enter reproducible dev environment
devbox shell

# Install packages
melos bootstrap

# Run all tests (requires Docker)
devbox run test

# Run unit tests only (no Docker)
devbox run test:unit

# Lint
devbox run analyze

# Format
devbox run format
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
