/// Runtime environment probes used by testcontainers-dart.
///
/// These free functions inspect the current process's host environment to
/// detect whether the code is running inside a Docker container, to discover
/// the default gateway IP address, and to identify the host operating system
/// and CPU architecture. The results drive connection-mode selection in
/// [DockerClient].
library;

import 'dart:io';

/// Returns `true` when the current process is running inside a Docker
/// container.
///
/// Detection strategy: checks for the existence of `/.dockerenv`, which
/// Docker places in every container's root filesystem.
///
/// Returns `false` on any I/O error and on non-Linux platforms where the
/// file is unlikely to exist.
bool insideContainer() => File('/.dockerenv').existsSync();

/// Returns the host machine's default-route gateway IP address.
///
/// Runs `ip route` and parses the line that starts with `default` to extract
/// the gateway address, e.g. `172.17.0.1`. This is the address through which
/// a container inside a Docker bridge network can reach the host.
///
/// Returns `null` if:
/// - the `ip` command is not available on the current platform,
/// - the command exits with a non-zero status,
/// - no default route is present, or
/// - any other I/O error occurs.
String? defaultGatewayIp() {
  try {
    final result = Process.runSync(
      'sh',
      ['-c', "ip route|awk '/default/ { print \$3 }'"],
    );
    if (result.exitCode != 0) {
      return null;
    }
    final ip = result.stdout.toString().trim();
    return ip.isNotEmpty ? ip : null;
  } catch (_) {
    return null;
  }
}

/// Returns `true` when the current CPU architecture is ARM (64-bit).
///
/// Runs `uname -m` and checks whether the machine type string equals
/// `arm64` or `aarch64`. This is used by [DockerContainer.maybeEmulateAmd64]
/// to automatically add the `platform: linux/amd64` option when running on
/// Apple Silicon or other ARM64 hosts.
///
/// Returns `false` if `uname` is not available or any error occurs.
bool isArm() {
  try {
    final result = Process.runSync('uname', ['-m']);
    final machine = result.stdout.toString().trim().toLowerCase();
    return machine == 'arm64' || machine == 'aarch64';
  } catch (_) {
    return false;
  }
}

/// Returns `true` when the current platform is macOS.
bool isMac() => Platform.isMacOS;

/// Returns `true` when the current platform is Linux.
bool isLinux() => Platform.isLinux;

/// Returns `true` when the current platform is Windows.
bool isWindows() => Platform.isWindows;

/// Returns the Docker container ID of the current process, or `null`.
///
/// Reads `/proc/self/cgroup` and looks for lines whose cgroup path starts with
/// `/docker/`. The 64-character hex string that follows is the container ID.
///
/// Returns `null` if:
/// - `/proc/self/cgroup` does not exist (non-Linux platforms),
/// - the process is not running inside a Docker container, or
/// - any I/O error occurs.
String? runningContainerId() {
  final cgroupFile = File('/proc/self/cgroup');
  if (!cgroupFile.existsSync()) {
    return null;
  }
  for (final line in cgroupFile.readAsLinesSync()) {
    final path = line.split(':').last;
    if (path.startsWith('/docker/')) {
      return path.substring('/docker/'.length);
    }
  }
  return null;
}
