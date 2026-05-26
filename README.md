# testcontainers-dart

A Dart port of [testcontainers-python](https://github.com/testcontainers/testcontainers-python) `core` + `compose` modules.

Testcontainers is a library that supports tests that need throwaway instances of real Docker containers — databases, message brokers, web servers, and more.

## Packages

| Package | Description |
|---------|-------------|
| `testcontainers_core` | Core container management, wait strategies, Docker client |
| `testcontainers_compose` | Docker Compose orchestration support |

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  testcontainers_core: ^1.0.0
```

Or use the Dart CLI:

```bash
dart pub add testcontainers_core
```

## Usage

### Single container

```dart
import 'package:testcontainers_core/testcontainers_core.dart';

await DockerContainer.use(
  DockerContainer('redis:7-alpine')
      .withExposedPorts([6379])
      .waitingFor(LogMessageWaitStrategy(r'Ready to accept connections')),
  (container) async {
    final host = await container.host;
    final port = await container.exposedPort(6379);
    // connect to redis on host:port
  },
);
```

### Docker Compose

```dart
import 'package:testcontainers_compose/testcontainers_compose.dart';

await DockerCompose.use(
  DockerCompose(context: 'test/fixtures'),
  (compose) async {
    final web = compose.container('web');
    final port = await web.exposedPort(8080);
    // make HTTP requests to localhost:port
  },
);
```

## Wait strategies

| Strategy | Description |
|----------|-------------|
| `LogMessageWaitStrategy` | Wait for a pattern in container logs |
| `HttpWaitStrategy` | Wait for an HTTP endpoint to respond |
| `HealthcheckWaitStrategy` | Wait for Docker healthcheck to report healthy |
| `PortWaitStrategy` | Wait for a TCP port to accept connections |
| `FileExistsWaitStrategy` | Wait for a file to exist in the container |
| `ContainerStatusWaitStrategy` | Wait for the container status to be `running` |
| `CompositeWaitStrategy` | Run multiple strategies in sequence |
| `ExecWaitStrategy` | Wait for a command to exit with a given code |

## Prerequisites

- Dart SDK ≥ 3.4.0
- Docker Desktop or Docker Engine
- [devbox](https://www.jetpack.io/devbox) (for local development)

## Development

```bash
devbox shell

devbox run analyze          # dart analyze --fatal-infos
devbox run test             # all tests (requires Docker)
devbox run test:unit        # unit tests only (no Docker)
devbox run test:integration # integration tests (requires Docker)
devbox run format           # check formatting
devbox run format:fix       # apply formatting
devbox run doc              # generate API documentation
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
