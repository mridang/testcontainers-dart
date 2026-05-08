# testcontainers

Core library for managing throwaway Docker containers in Dart tests.

## Usage

```dart
import 'package:testcontainers/testcontainers.dart';

void main() async {
  await DockerContainer.use(
    DockerContainer('nginx:alpine').withExposedPorts([80]),
    (container) async {
      final port = await container.getExposedPortAsync(80);
      print('nginx running on port $port');
    },
  );
}
```

## Wait Strategies

```dart
// Wait for a log message
container.waitingFor(LogMessageWaitStrategy('Server started'));

// Wait for an HTTP endpoint
container.waitingFor(HttpWaitStrategy(8080).forStatusCode(200));

// Wait for a TCP port
container.waitingFor(PortWaitStrategy(5432));

// Combine strategies
container.waitingFor(CompositeWaitStrategy([
  LogMessageWaitStrategy('ready'),
  PortWaitStrategy(5432),
]));
```

## Network

```dart
await Network.use((network) async {
  final a = DockerContainer('alpine').withNetwork(network);
  final b = DockerContainer('alpine').withNetwork(network);
  // a and b can communicate
});
```

## License

Apache 2.0
