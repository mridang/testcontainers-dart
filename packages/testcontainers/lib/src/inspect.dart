/// Strongly-typed data classes for the Docker `GET /containers/{id}/json`
/// response.
///
/// Each class has a [fromJson] factory that reads only the fields it knows
/// about; unknown keys from the Docker API are silently ignored. This makes
/// the model forward-compatible with newer Docker Engine versions.
///
/// The top-level class is [ContainerInspectInfo]. The other classes model the
/// nested sub-objects of the inspect response.
library;

/// A single health-check execution record.
///
/// Docker stores the most recent [ContainerHealth.log] entries (up to the
/// configured `--health-retries` limit). Each entry describes one run of the
/// health-check command.
class ContainerLog {
  /// RFC 3339 timestamp when the health check started.
  final String? start;

  /// RFC 3339 timestamp when the health check finished.
  final String? end;

  /// Exit code returned by the health-check command.
  ///
  /// `0` means healthy; any other value is unhealthy.
  final int? exitCode;

  /// Combined stdout + stderr output from the health-check command.
  final String? output;

  /// Creates a [ContainerLog] with the given fields.
  const ContainerLog({this.start, this.end, this.exitCode, this.output});

  /// Deserialises a [ContainerLog] from Docker's JSON representation.
  factory ContainerLog.fromJson(Map<String, dynamic> json) => ContainerLog(
        start: json['Start'] as String?,
        end: json['End'] as String?,
        exitCode: json['ExitCode'] as int?,
        output: json['Output'] as String?,
      );
}

/// The aggregated health status of a container.
///
/// Populated only when the container has a `HEALTHCHECK` instruction.
class ContainerHealth {
  /// Overall health status string: `'healthy'`, `'unhealthy'`, or
  /// `'starting'`.
  final String? status;

  /// Number of consecutive health-check failures since the last success.
  final int? failingStreak;

  /// The most recent health-check log entries, newest first.
  final List<ContainerLog>? log;

  /// Creates a [ContainerHealth] with the given fields.
  const ContainerHealth({this.status, this.failingStreak, this.log});

  /// Deserialises a [ContainerHealth] from Docker's JSON representation.
  factory ContainerHealth.fromJson(Map<String, dynamic> json) =>
      ContainerHealth(
        status: json['Status'] as String?,
        failingStreak: json['FailingStreak'] as int?,
        log: (json['Log'] as List<dynamic>?)
            ?.map((e) => ContainerLog.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The full lifecycle state of a container.
///
/// Returned as the `State` field in a Docker inspect response.
class ContainerState {
  /// Lifecycle status string: `'created'`, `'running'`, `'paused'`,
  /// `'restarting'`, `'removing'`, `'exited'`, or `'dead'`.
  final String? status;

  /// `true` when the container is currently running.
  final bool? running;

  /// `true` when the container is paused.
  final bool? paused;

  /// `true` when the container is in the process of restarting.
  final bool? restarting;

  /// `true` when the container was killed due to an out-of-memory condition.
  final bool? oomKilled;

  /// `true` when the container is in the `dead` state.
  final bool? dead;

  /// The PID of the container's init process on the host.
  final int? pid;

  /// Exit code of the container's main process (meaningful when [running] is
  /// `false`).
  final int? exitCode;

  /// Error string describing why the container stopped, if applicable.
  final String? error;

  /// RFC 3339 timestamp when the container last started.
  final String? startedAt;

  /// RFC 3339 timestamp when the container last stopped.
  final String? finishedAt;

  /// Health-check state, or `null` if no health check is configured.
  final ContainerHealth? health;

  /// Creates a [ContainerState] with the given fields.
  const ContainerState({
    this.status,
    this.running,
    this.paused,
    this.restarting,
    this.oomKilled,
    this.dead,
    this.pid,
    this.exitCode,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.health,
  });

  /// Deserialises a [ContainerState] from Docker's JSON representation.
  factory ContainerState.fromJson(Map<String, dynamic> json) {
    final healthData = json['Health'] as Map<String, dynamic>?;
    return ContainerState(
      status: json['Status'] as String?,
      running: json['Running'] as bool?,
      paused: json['Paused'] as bool?,
      restarting: json['Restarting'] as bool?,
      oomKilled: json['OOMKilled'] as bool?,
      dead: json['Dead'] as bool?,
      pid: json['Pid'] as int?,
      exitCode: json['ExitCode'] as int?,
      error: json['Error'] as String?,
      startedAt: json['StartedAt'] as String?,
      finishedAt: json['FinishedAt'] as String?,
      health: healthData != null ? ContainerHealth.fromJson(healthData) : null,
    );
  }
}

/// The platform (OS and architecture) of a container image.
class ContainerPlatform {
  /// CPU architecture string, e.g. `'amd64'` or `'arm64'`.
  final String? architecture;

  /// Operating system string, e.g. `'linux'` or `'windows'`.
  final String? os;

  /// Architecture variant, e.g. `'v8'` for ARMv8.
  final String? variant;

  /// Creates a [ContainerPlatform] with the given fields.
  const ContainerPlatform({this.architecture, this.os, this.variant});

  /// Deserialises a [ContainerPlatform] from Docker's JSON representation.
  factory ContainerPlatform.fromJson(Map<String, dynamic> json) =>
      ContainerPlatform(
        architecture: json['architecture'] as String?,
        os: json['os'] as String?,
        variant: json['variant'] as String?,
      );
}

/// Describes a layer in an image manifest (OCI image spec).
class ContainerImageManifestDescriptor {
  /// MIME type of the manifest or layer.
  final String? mediaType;

  /// Content-addressable digest (`sha256:…`).
  final String? digest;

  /// Size in bytes of the referenced object.
  final int? size;

  /// List of URLs where the content can be obtained.
  final List<String>? urls;

  /// Arbitrary annotations attached to this manifest descriptor.
  final Map<String, String>? annotations;

  /// Embedded content data (rarely used).
  final Object? data;

  /// Platform information for multi-arch images.
  final ContainerPlatform? platform;

  /// OCI artifact type string, if applicable.
  final String? artifactType;

  /// Creates a [ContainerImageManifestDescriptor] with the given fields.
  const ContainerImageManifestDescriptor({
    this.mediaType,
    this.digest,
    this.size,
    this.urls,
    this.annotations,
    this.data,
    this.platform,
    this.artifactType,
  });

  /// Deserialises a [ContainerImageManifestDescriptor] from Docker's JSON.
  factory ContainerImageManifestDescriptor.fromJson(
    Map<String, dynamic> json,
  ) {
    final platformData = json['platform'] as Map<String, dynamic>?;
    return ContainerImageManifestDescriptor(
      mediaType: json['mediaType'] as String?,
      digest: json['digest'] as String?,
      size: json['size'] as int?,
      urls: (json['urls'] as List<dynamic>?)?.cast<String>(),
      annotations: (json['annotations'] as Map<String, dynamic>?)
          ?.cast<String, String>(),
      data: json['data'],
      platform: platformData != null
          ? ContainerPlatform.fromJson(platformData)
          : null,
      artifactType: json['artifactType'] as String?,
    );
  }
}

/// A single entry in the `BlkioWeightDevice` host-config list.
class ContainerBlkioWeightDevice {
  /// Device path on the host, e.g. `'/dev/sda'`.
  final String? path;

  /// Relative I/O weight for the device (10–1000).
  final int? weight;

  /// Creates a [ContainerBlkioWeightDevice] with the given fields.
  const ContainerBlkioWeightDevice({this.path, this.weight});

  /// Deserialises from Docker's JSON representation.
  factory ContainerBlkioWeightDevice.fromJson(Map<String, dynamic> json) =>
      ContainerBlkioWeightDevice(
        path: json['Path'] as String?,
        weight: json['Weight'] as int?,
      );
}

/// A single entry in a blkio device I/O rate list.
///
/// Used for `BlkioDeviceReadBps`, `BlkioDeviceWriteBps`,
/// `BlkioDeviceReadIOps`, and `BlkioDeviceWriteIOps`.
class ContainerBlkioDeviceRate {
  /// Device path on the host.
  final String? path;

  /// Rate limit (bytes per second or I/O operations per second).
  final int? rate;

  /// Creates a [ContainerBlkioDeviceRate] with the given fields.
  const ContainerBlkioDeviceRate({this.path, this.rate});

  /// Deserialises from Docker's JSON representation.
  factory ContainerBlkioDeviceRate.fromJson(Map<String, dynamic> json) =>
      ContainerBlkioDeviceRate(
        path: json['Path'] as String?,
        rate: json['Rate'] as int?,
      );
}

/// A host device exposed inside the container.
class ContainerDeviceMapping {
  /// Path to the device on the host.
  final String? pathOnHost;

  /// Path under which the device appears inside the container.
  final String? pathInContainer;

  /// cgroup device permissions string, e.g. `'rwm'`.
  final String? cgroupPermissions;

  /// Creates a [ContainerDeviceMapping] with the given fields.
  const ContainerDeviceMapping({
    this.pathOnHost,
    this.pathInContainer,
    this.cgroupPermissions,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerDeviceMapping.fromJson(Map<String, dynamic> json) =>
      ContainerDeviceMapping(
        pathOnHost: json['PathOnHost'] as String?,
        pathInContainer: json['PathInContainer'] as String?,
        cgroupPermissions: json['CgroupPermissions'] as String?,
      );
}

/// A request for generic device access (e.g. GPU via the NVIDIA device
/// plugin).
class ContainerDeviceRequest {
  /// Driver to use for the request (e.g. `'nvidia'`).
  final String? driver;

  /// Number of devices to request (`-1` for all).
  final int? count;

  /// Specific device IDs to request.
  final List<String>? deviceIDs;

  /// Capability sets, e.g. `[['gpu'], ['nvidia', 'compute']]`.
  final List<List<String>>? capabilities;

  /// Driver-specific options.
  final Map<String, String>? options;

  /// Creates a [ContainerDeviceRequest] with the given fields.
  const ContainerDeviceRequest({
    this.driver,
    this.count,
    this.deviceIDs,
    this.capabilities,
    this.options,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerDeviceRequest.fromJson(Map<String, dynamic> json) =>
      ContainerDeviceRequest(
        driver: json['Driver'] as String?,
        count: json['Count'] as int?,
        deviceIDs: (json['DeviceIDs'] as List<dynamic>?)?.cast<String>(),
        capabilities: (json['Capabilities'] as List<dynamic>?)
            ?.map((e) => (e as List<dynamic>).cast<String>())
            .toList(),
        options:
            (json['Options'] as Map<String, dynamic>?)?.cast<String, String>(),
      );
}

/// A ulimit (resource limit) applied to the container.
class ContainerUlimit {
  /// The ulimit type, e.g. `'nofile'` or `'nproc'`.
  final String? name;

  /// Soft limit value.
  final int? soft;

  /// Hard limit value.
  final int? hard;

  /// Creates a [ContainerUlimit] with the given fields.
  const ContainerUlimit({this.name, this.soft, this.hard});

  /// Deserialises from Docker's JSON representation.
  factory ContainerUlimit.fromJson(Map<String, dynamic> json) =>
      ContainerUlimit(
        name: json['Name'] as String?,
        soft: json['Soft'] as int?,
        hard: json['Hard'] as int?,
      );
}

/// Logging driver configuration for a container.
class ContainerLogConfig {
  /// Log driver name, e.g. `'json-file'`, `'syslog'`, `'none'`.
  final String? type;

  /// Driver-specific configuration options.
  final Map<String, String>? config;

  /// Creates a [ContainerLogConfig] with the given fields.
  const ContainerLogConfig({this.type, this.config});

  /// Deserialises from Docker's JSON representation.
  factory ContainerLogConfig.fromJson(Map<String, dynamic> json) =>
      ContainerLogConfig(
        type: json['Type'] as String?,
        config:
            (json['Config'] as Map<String, dynamic>?)?.cast<String, String>(),
      );
}

/// A single host-to-container port binding.
///
/// The Docker daemon maps a container port to an ephemeral host port.
/// Multiple [ContainerPortBinding] entries can exist for the same container
/// port (e.g. to bind on both `0.0.0.0` and `::` for IPv4 + IPv6).
class ContainerPortBinding {
  /// Host IP address to bind on, e.g. `'0.0.0.0'` or `'127.0.0.1'`.
  final String? hostIp;

  /// Ephemeral port number on the host, as a string (Docker's JSON format).
  final String? hostPort;

  /// Creates a [ContainerPortBinding] with the given fields.
  const ContainerPortBinding({this.hostIp, this.hostPort});

  /// Deserialises from Docker's JSON representation.
  factory ContainerPortBinding.fromJson(Map<String, dynamic> json) =>
      ContainerPortBinding(
        hostIp: json['HostIp'] as String?,
        hostPort: json['HostPort'] as String?,
      );
}

/// The restart policy applied to a container.
class ContainerRestartPolicy {
  /// Policy name: `'no'`, `'always'`, `'on-failure'`, or
  /// `'unless-stopped'`.
  final String? name;

  /// Maximum number of restart attempts (meaningful for `'on-failure'`).
  final int? maximumRetryCount;

  /// Creates a [ContainerRestartPolicy] with the given fields.
  const ContainerRestartPolicy({this.name, this.maximumRetryCount});

  /// Deserialises from Docker's JSON representation.
  factory ContainerRestartPolicy.fromJson(Map<String, dynamic> json) =>
      ContainerRestartPolicy(
        name: json['Name'] as String?,
        maximumRetryCount: json['MaximumRetryCount'] as int?,
      );
}

/// Mount propagation options for a bind mount.
class ContainerBindOptions {
  /// Propagation mode: `'private'`, `'rprivate'`, `'shared'`, `'rshared'`,
  /// `'slave'`, or `'rslave'`.
  final String? propagation;

  /// Whether to disable recursive bind mounts.
  final bool? nonRecursive;

  /// Whether to create the mount point if it does not exist.
  final bool? createMountpoint;

  /// Whether the bind mount is non-recursively read-only.
  final bool? readOnlyNonRecursive;

  /// Whether to force a recursive read-only bind mount.
  final bool? readOnlyForceRecursive;

  /// Creates a [ContainerBindOptions] with the given fields.
  const ContainerBindOptions({
    this.propagation,
    this.nonRecursive,
    this.createMountpoint,
    this.readOnlyNonRecursive,
    this.readOnlyForceRecursive,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerBindOptions.fromJson(Map<String, dynamic> json) =>
      ContainerBindOptions(
        propagation: json['Propagation'] as String?,
        nonRecursive: json['NonRecursive'] as bool?,
        createMountpoint: json['CreateMountpoint'] as bool?,
        readOnlyNonRecursive: json['ReadOnlyNonRecursive'] as bool?,
        readOnlyForceRecursive: json['ReadOnlyForceRecursive'] as bool?,
      );
}

/// Driver configuration for a named volume.
class ContainerVolumeDriverConfig {
  /// Volume driver name, e.g. `'local'`.
  final String? name;

  /// Driver-specific options.
  final Map<String, String>? options;

  /// Creates a [ContainerVolumeDriverConfig] with the given fields.
  const ContainerVolumeDriverConfig({this.name, this.options});

  /// Deserialises from Docker's JSON representation.
  factory ContainerVolumeDriverConfig.fromJson(Map<String, dynamic> json) =>
      ContainerVolumeDriverConfig(
        name: json['Name'] as String?,
        options:
            (json['Options'] as Map<String, dynamic>?)?.cast<String, String>(),
      );
}

/// Options for a volume mount.
class ContainerVolumeOptions {
  /// When `true`, disables copying data from the container path to the volume
  /// on first use.
  final bool? noCopy;

  /// Labels applied to the volume.
  final Map<String, String>? labels;

  /// Volume driver configuration.
  final ContainerVolumeDriverConfig? driverConfig;

  /// Sub-path within the volume to mount.
  final String? subpath;

  /// Creates a [ContainerVolumeOptions] with the given fields.
  const ContainerVolumeOptions({
    this.noCopy,
    this.labels,
    this.driverConfig,
    this.subpath,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerVolumeOptions.fromJson(Map<String, dynamic> json) {
    final dc = json['DriverConfig'] as Map<String, dynamic>?;
    return ContainerVolumeOptions(
      noCopy: json['NoCopy'] as bool?,
      labels: (json['Labels'] as Map<String, dynamic>?)?.cast<String, String>(),
      driverConfig:
          dc != null ? ContainerVolumeDriverConfig.fromJson(dc) : null,
      subpath: json['Subpath'] as String?,
    );
  }
}

/// Options for an image-based mount.
class ContainerImageOptions {
  /// Sub-path within the image to mount.
  final String? subpath;

  /// Creates a [ContainerImageOptions] with the given fields.
  const ContainerImageOptions({this.subpath});

  /// Deserialises from Docker's JSON representation.
  factory ContainerImageOptions.fromJson(Map<String, dynamic> json) =>
      ContainerImageOptions(subpath: json['Subpath'] as String?);
}

/// Options for a `tmpfs` (in-memory) mount.
class ContainerTmpfsOptions {
  /// Maximum size of the tmpfs in bytes.
  final int? sizeBytes;

  /// Unix permission bits for the tmpfs root directory.
  final int? mode;

  /// Additional mount options as key-value pairs.
  final List<List<String>>? options;

  /// Creates a [ContainerTmpfsOptions] with the given fields.
  const ContainerTmpfsOptions({this.sizeBytes, this.mode, this.options});

  /// Deserialises from Docker's JSON representation.
  factory ContainerTmpfsOptions.fromJson(Map<String, dynamic> json) =>
      ContainerTmpfsOptions(
        sizeBytes: json['SizeBytes'] as int?,
        mode: json['Mode'] as int?,
        options: (json['Options'] as List<dynamic>?)
            ?.map((inner) => (inner as List<dynamic>).cast<String>())
            .toList(),
      );
}

/// A mount point attached to the container (as declared in `HostConfig.Mounts`).
class ContainerMountPoint {
  /// Mount type: `'bind'`, `'volume'`, `'tmpfs'`, or `'image'`.
  final String? type;

  /// Source path on the host (for bind mounts) or volume name.
  final String? source;

  /// Target path inside the container.
  final String? target;

  /// Whether the mount is read-only.
  final bool? readOnly;

  /// Consistency requirement: `'default'`, `'consistent'`, `'cached'`, or
  /// `'delegated'`.
  final String? consistency;

  /// Bind-mount-specific options. Present only when [type] is `'bind'`.
  final ContainerBindOptions? bindOptions;

  /// Volume-mount-specific options. Present only when [type] is `'volume'`.
  final ContainerVolumeOptions? volumeOptions;

  /// Image-mount-specific options. Present only when [type] is `'image'`.
  final ContainerImageOptions? imageOptions;

  /// Tmpfs-mount-specific options. Present only when [type] is `'tmpfs'`.
  final ContainerTmpfsOptions? tmpfsOptions;

  /// Creates a [ContainerMountPoint] with the given fields.
  const ContainerMountPoint({
    this.type,
    this.source,
    this.target,
    this.readOnly,
    this.consistency,
    this.bindOptions,
    this.volumeOptions,
    this.imageOptions,
    this.tmpfsOptions,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerMountPoint.fromJson(Map<String, dynamic> json) {
    final bo = json['BindOptions'] as Map<String, dynamic>?;
    final vo = json['VolumeOptions'] as Map<String, dynamic>?;
    final io = json['ImageOptions'] as Map<String, dynamic>?;
    final to = json['TmpfsOptions'] as Map<String, dynamic>?;
    return ContainerMountPoint(
      type: json['Type'] as String?,
      source: json['Source'] as String?,
      target: json['Target'] as String?,
      readOnly: json['ReadOnly'] as bool?,
      consistency: json['Consistency'] as String?,
      bindOptions: bo != null ? ContainerBindOptions.fromJson(bo) : null,
      volumeOptions: vo != null ? ContainerVolumeOptions.fromJson(vo) : null,
      imageOptions: io != null ? ContainerImageOptions.fromJson(io) : null,
      tmpfsOptions: to != null ? ContainerTmpfsOptions.fromJson(to) : null,
    );
  }
}

/// The host configuration applied when the container was created.
///
/// This is the Dart model for Docker's `HostConfig` JSON object, which
/// contains resource constraints, port bindings, volume mounts, and many
/// other runtime settings.
class ContainerHostConfig {
  /// CPU shares relative to other containers (default `0` = unlimited).
  final int? cpuShares;

  /// Memory limit in bytes (`0` = unlimited).
  final int? memory;

  /// cgroup parent for the container.
  final String? cgroupParent;

  /// Block I/O weight (10–1000, or `0` for default).
  final int? blkioWeight;

  /// Per-device block I/O weight settings.
  final List<ContainerBlkioWeightDevice>? blkioWeightDevice;

  /// Per-device read bandwidth limits (bytes per second).
  final List<ContainerBlkioDeviceRate>? blkioDeviceReadBps;

  /// Per-device write bandwidth limits (bytes per second).
  final List<ContainerBlkioDeviceRate>? blkioDeviceWriteBps;

  /// Per-device read IOPS limits.
  final List<ContainerBlkioDeviceRate>? blkioDeviceReadIOps;

  /// Per-device write IOPS limits.
  final List<ContainerBlkioDeviceRate>? blkioDeviceWriteIOps;

  /// Length of the CPU CFS period in microseconds.
  final int? cpuPeriod;

  /// CPU CFS quota in microseconds per [cpuPeriod].
  final int? cpuQuota;

  /// CPU real-time period in microseconds.
  final int? cpuRealtimePeriod;

  /// CPU real-time runtime in microseconds.
  final int? cpuRealtimeRuntime;

  /// CPUs to use, e.g. `'0-3'` or `'1,3'`.
  final String? cpusetCpus;

  /// Memory nodes to use, e.g. `'0-1'`.
  final String? cpusetMems;

  /// Host devices exposed inside the container.
  final List<ContainerDeviceMapping>? devices;

  /// cgroup device rules applied to the container.
  final List<String>? deviceCgroupRules;

  /// Generic device requests (e.g. for GPU access).
  final List<ContainerDeviceRequest>? deviceRequests;

  /// Hard limit on the TCP memory for the container's kernel.
  final int? kernelMemoryTCP;

  /// Soft memory limit in bytes.
  final int? memoryReservation;

  /// Total memory + swap limit in bytes (`-1` = unlimited).
  final int? memorySwap;

  /// Tune container memory swappiness (`0`–`100`; `-1` for host default).
  final int? memorySwappiness;

  /// CPU quota in units of 1e-9 CPUs.
  final int? nanoCpus;

  /// Disable the OOM killer for this container.
  final bool? oomKillDisable;

  /// Run an init process inside the container.
  final bool? init;

  /// Limit on the number of processes inside the container.
  final int? pidsLimit;

  /// ulimits applied to the container.
  final List<ContainerUlimit>? ulimits;

  /// Windows-only: number of usable CPUs.
  final int? cpuCount;

  /// Windows-only: percentage of CPU usage.
  final int? cpuPercent;

  /// Windows-only: maximum IOPS for the container's storage.
  final int? ioMaximumIOps;

  /// Windows-only: maximum I/O bandwidth for the container's storage.
  final int? ioMaximumBandwidth;

  /// Volume bind-mount strings in `host:container:mode` format.
  final List<String>? binds;

  /// Path to the file containing the container ID.
  final String? containerIDFile;

  /// Logging driver and its options.
  final ContainerLogConfig? logConfig;

  /// Network mode for the container, e.g. `'bridge'`, `'host'`, `'none'`,
  /// or a custom network name.
  final String? networkMode;

  /// Published port bindings: container port spec → list of host bindings.
  ///
  /// Keys are in `port/proto` format, e.g. `'80/tcp'`.
  final Map<String, List<ContainerPortBinding>?>? portBindings;

  /// Restart policy for the container.
  final ContainerRestartPolicy? restartPolicy;

  /// Whether Docker will remove the container when it exits.
  final bool? autoRemove;

  /// Volume driver for volumes created by this container.
  final String? volumeDriver;

  /// Container names from which to mount volumes.
  final List<String>? volumesFrom;

  /// Mount points declared using the `--mount` syntax.
  final List<ContainerMountPoint>? mounts;

  /// Console size `[rows, columns]` (Windows only).
  final List<int>? consoleSize;

  /// OCI annotations.
  final Map<String, String>? annotations;

  /// Linux capabilities to add.
  final List<String>? capAdd;

  /// Linux capabilities to drop.
  final List<String>? capDrop;

  /// cgroup namespace mode: `'host'` or `'private'`.
  final String? cgroupnsMode;

  /// Custom DNS servers.
  final List<String>? dns;

  /// DNS options passed to the container.
  final List<String>? dnsOptions;

  /// DNS search domains.
  final List<String>? dnsSearch;

  /// Extra host entries added to `/etc/hosts`.
  final List<String>? extraHosts;

  /// Additional groups the container process belongs to.
  final List<String>? groupAdd;

  /// IPC mode: `'shareable'`, `'private'`, or `'container:<name>'`.
  final String? ipcMode;

  /// cgroup v2 unified hierarchy path.
  final String? cgroup;

  /// Container names to link to (legacy).
  final List<String>? links;

  /// OOM score adjustment for the container process.
  final int? oomScoreAdj;

  /// PID namespace mode: `'host'` or `'container:<name>'`.
  final String? pidMode;

  /// Whether to grant extended privileges to the container.
  final bool? privileged;

  /// Whether to publish all exposed ports to random host ports.
  final bool? publishAllPorts;

  /// Whether to mount the container's root filesystem as read-only.
  final bool? readonlyRootfs;

  /// Security options, e.g. `['no-new-privileges:true']`.
  final List<String>? securityOpt;

  /// Storage driver options.
  final Map<String, String>? storageOpt;

  /// Tmpfs mounts: container path → options string.
  final Map<String, String>? tmpfs;

  /// UTS namespace mode.
  final String? utsMode;

  /// User namespace mode: `''` (default), `'host'`.
  final String? usernsMode;

  /// Size of `/dev/shm` in bytes.
  final int? shmSize;

  /// Sysctl settings for the container.
  final Map<String, String>? sysctls;

  /// OCI runtime to use, e.g. `'runc'` or `'nvidia'`.
  final String? runtime;

  /// Windows-only: isolation technology, e.g. `'process'` or `'hyperv'`.
  final String? isolation;

  /// Paths masked inside the container (made inaccessible).
  final List<String>? maskedPaths;

  /// Paths made read-only inside the container.
  final List<String>? readonlyPaths;

  /// Creates a [ContainerHostConfig] with the given fields.
  const ContainerHostConfig({
    this.cpuShares,
    this.memory,
    this.cgroupParent,
    this.blkioWeight,
    this.blkioWeightDevice,
    this.blkioDeviceReadBps,
    this.blkioDeviceWriteBps,
    this.blkioDeviceReadIOps,
    this.blkioDeviceWriteIOps,
    this.cpuPeriod,
    this.cpuQuota,
    this.cpuRealtimePeriod,
    this.cpuRealtimeRuntime,
    this.cpusetCpus,
    this.cpusetMems,
    this.devices,
    this.deviceCgroupRules,
    this.deviceRequests,
    this.kernelMemoryTCP,
    this.memoryReservation,
    this.memorySwap,
    this.memorySwappiness,
    this.nanoCpus,
    this.oomKillDisable,
    this.init,
    this.pidsLimit,
    this.ulimits,
    this.cpuCount,
    this.cpuPercent,
    this.ioMaximumIOps,
    this.ioMaximumBandwidth,
    this.binds,
    this.containerIDFile,
    this.logConfig,
    this.networkMode,
    this.portBindings,
    this.restartPolicy,
    this.autoRemove,
    this.volumeDriver,
    this.volumesFrom,
    this.mounts,
    this.consoleSize,
    this.annotations,
    this.capAdd,
    this.capDrop,
    this.cgroupnsMode,
    this.dns,
    this.dnsOptions,
    this.dnsSearch,
    this.extraHosts,
    this.groupAdd,
    this.ipcMode,
    this.cgroup,
    this.links,
    this.oomScoreAdj,
    this.pidMode,
    this.privileged,
    this.publishAllPorts,
    this.readonlyRootfs,
    this.securityOpt,
    this.storageOpt,
    this.tmpfs,
    this.utsMode,
    this.usernsMode,
    this.shmSize,
    this.sysctls,
    this.runtime,
    this.isolation,
    this.maskedPaths,
    this.readonlyPaths,
  });

  /// Deserialises a [ContainerHostConfig] from Docker's JSON representation.
  factory ContainerHostConfig.fromJson(Map<String, dynamic> json) {
    Map<String, List<ContainerPortBinding>?>? portBindings;
    final raw = json['PortBindings'] as Map<String, dynamic>?;
    if (raw != null) {
      portBindings = {};
      for (final entry in raw.entries) {
        final bindings = entry.value as List<dynamic>?;
        portBindings[entry.key] = bindings
            ?.map(
              (b) => ContainerPortBinding.fromJson(b as Map<String, dynamic>),
            )
            .toList();
      }
    }

    List<T>? parseList<T>(
      String key,
      T Function(Map<String, dynamic>) fromJson,
    ) {
      final list = json[key] as List<dynamic>?;
      return list?.map((e) => fromJson(e as Map<String, dynamic>)).toList();
    }

    return ContainerHostConfig(
      cpuShares: json['CpuShares'] as int?,
      memory: json['Memory'] as int?,
      cgroupParent: json['CgroupParent'] as String?,
      blkioWeight: json['BlkioWeight'] as int?,
      blkioWeightDevice: parseList(
        'BlkioWeightDevice',
        ContainerBlkioWeightDevice.fromJson,
      ),
      blkioDeviceReadBps: parseList(
        'BlkioDeviceReadBps',
        ContainerBlkioDeviceRate.fromJson,
      ),
      blkioDeviceWriteBps: parseList(
        'BlkioDeviceWriteBps',
        ContainerBlkioDeviceRate.fromJson,
      ),
      blkioDeviceReadIOps: parseList(
        'BlkioDeviceReadIOps',
        ContainerBlkioDeviceRate.fromJson,
      ),
      blkioDeviceWriteIOps: parseList(
        'BlkioDeviceWriteIOps',
        ContainerBlkioDeviceRate.fromJson,
      ),
      cpuPeriod: json['CpuPeriod'] as int?,
      cpuQuota: json['CpuQuota'] as int?,
      cpuRealtimePeriod: json['CpuRealtimePeriod'] as int?,
      cpuRealtimeRuntime: json['CpuRealtimeRuntime'] as int?,
      cpusetCpus: json['CpusetCpus'] as String?,
      cpusetMems: json['CpusetMems'] as String?,
      devices: parseList('Devices', ContainerDeviceMapping.fromJson),
      deviceCgroupRules:
          (json['DeviceCgroupRules'] as List<dynamic>?)?.cast<String>(),
      deviceRequests: parseList(
        'DeviceRequests',
        ContainerDeviceRequest.fromJson,
      ),
      kernelMemoryTCP: json['KernelMemoryTCP'] as int?,
      memoryReservation: json['MemoryReservation'] as int?,
      memorySwap: json['MemorySwap'] as int?,
      memorySwappiness: json['MemorySwappiness'] as int?,
      nanoCpus: json['NanoCpus'] as int?,
      oomKillDisable: json['OomKillDisable'] as bool?,
      init: json['Init'] as bool?,
      pidsLimit: json['PidsLimit'] as int?,
      ulimits: parseList('Ulimits', ContainerUlimit.fromJson),
      cpuCount: json['CpuCount'] as int?,
      cpuPercent: json['CpuPercent'] as int?,
      ioMaximumIOps: json['IOMaximumIOps'] as int?,
      ioMaximumBandwidth: json['IOMaximumBandwidth'] as int?,
      binds: (json['Binds'] as List<dynamic>?)?.cast<String>(),
      containerIDFile: json['ContainerIDFile'] as String?,
      logConfig: json['LogConfig'] != null
          ? ContainerLogConfig.fromJson(
              json['LogConfig'] as Map<String, dynamic>,
            )
          : null,
      networkMode: json['NetworkMode'] as String?,
      portBindings: portBindings,
      restartPolicy: json['RestartPolicy'] != null
          ? ContainerRestartPolicy.fromJson(
              json['RestartPolicy'] as Map<String, dynamic>,
            )
          : null,
      autoRemove: json['AutoRemove'] as bool?,
      volumeDriver: json['VolumeDriver'] as String?,
      volumesFrom: (json['VolumesFrom'] as List<dynamic>?)?.cast<String>(),
      mounts: parseList('Mounts', ContainerMountPoint.fromJson),
      consoleSize: (json['ConsoleSize'] as List<dynamic>?)?.cast<int>(),
      annotations: (json['Annotations'] as Map<String, dynamic>?)
          ?.cast<String, String>(),
      capAdd: (json['CapAdd'] as List<dynamic>?)?.cast<String>(),
      capDrop: (json['CapDrop'] as List<dynamic>?)?.cast<String>(),
      cgroupnsMode: json['CgroupnsMode'] as String?,
      dns: (json['Dns'] as List<dynamic>?)?.cast<String>(),
      dnsOptions: (json['DnsOptions'] as List<dynamic>?)?.cast<String>(),
      dnsSearch: (json['DnsSearch'] as List<dynamic>?)?.cast<String>(),
      extraHosts: (json['ExtraHosts'] as List<dynamic>?)?.cast<String>(),
      groupAdd: (json['GroupAdd'] as List<dynamic>?)?.cast<String>(),
      ipcMode: json['IpcMode'] as String?,
      cgroup: json['Cgroup'] as String?,
      links: (json['Links'] as List<dynamic>?)?.cast<String>(),
      oomScoreAdj: json['OomScoreAdj'] as int?,
      pidMode: json['PidMode'] as String?,
      privileged: json['Privileged'] as bool?,
      publishAllPorts: json['PublishAllPorts'] as bool?,
      readonlyRootfs: json['ReadonlyRootfs'] as bool?,
      securityOpt: (json['SecurityOpt'] as List<dynamic>?)?.cast<String>(),
      storageOpt:
          (json['StorageOpt'] as Map<String, dynamic>?)?.cast<String, String>(),
      tmpfs: (json['Tmpfs'] as Map<String, dynamic>?)?.cast<String, String>(),
      utsMode: json['UTSMode'] as String?,
      usernsMode: json['UsernsMode'] as String?,
      shmSize: json['ShmSize'] as int?,
      sysctls:
          (json['Sysctls'] as Map<String, dynamic>?)?.cast<String, String>(),
      runtime: json['Runtime'] as String?,
      isolation: json['Isolation'] as String?,
      maskedPaths: (json['MaskedPaths'] as List<dynamic>?)?.cast<String>(),
      readonlyPaths: (json['ReadonlyPaths'] as List<dynamic>?)?.cast<String>(),
    );
  }
}

/// The storage driver and its metadata for a container's writable layer.
class ContainerGraphDriver {
  /// Storage driver name, e.g. `'overlay2'`.
  final String? name;

  /// Driver-specific metadata (e.g. layer diff paths).
  final Map<String, String>? data;

  /// Creates a [ContainerGraphDriver] with the given fields.
  const ContainerGraphDriver({this.name, this.data});

  /// Deserialises from Docker's JSON representation.
  factory ContainerGraphDriver.fromJson(Map<String, dynamic> json) =>
      ContainerGraphDriver(
        name: json['Name'] as String?,
        data: (json['Data'] as Map<String, dynamic>?)?.cast<String, String>(),
      );
}

/// A volume or bind mount that is currently attached to a running container.
///
/// Returned in the `Mounts` array of a container inspect response; represents
/// the resolved, active state rather than the declared intent captured in
/// [ContainerMountPoint].
class ContainerMount {
  /// Mount type: `'bind'`, `'volume'`, or `'tmpfs'`.
  final String? type;

  /// Name of the Docker volume (only for `type == 'volume'`).
  final String? name;

  /// Source path on the host.
  final String? source;

  /// Destination path inside the container.
  final String? destination;

  /// Volume driver (only for `type == 'volume'`).
  final String? driver;

  /// Mount mode string, e.g. `'rw'` or `'ro'`.
  final String? mode;

  /// Whether the mount is read-write.
  final bool? rw;

  /// Mount propagation mode.
  final String? propagation;

  /// Creates a [ContainerMount] with the given fields.
  const ContainerMount({
    this.type,
    this.name,
    this.source,
    this.destination,
    this.driver,
    this.mode,
    this.rw,
    this.propagation,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerMount.fromJson(Map<String, dynamic> json) => ContainerMount(
        type: json['Type'] as String?,
        name: json['Name'] as String?,
        source: json['Source'] as String?,
        destination: json['Destination'] as String?,
        driver: json['Driver'] as String?,
        mode: json['Mode'] as String?,
        rw: json['RW'] as bool?,
        propagation: json['Propagation'] as String?,
      );
}

/// The health-check configuration baked into an image or specified at
/// container creation time.
class ContainerHealthcheck {
  /// Health-check command, e.g. `['CMD', 'curl', '-f', 'http://localhost/']`.
  ///
  /// The first element is the test type: `'CMD'`, `'CMD-SHELL'`, or `'NONE'`.
  final List<String>? test;

  /// Interval between health checks in nanoseconds.
  final int? interval;

  /// Maximum time to wait for a health check to complete, in nanoseconds.
  final int? timeout;

  /// Number of consecutive failures needed to declare the container unhealthy.
  final int? retries;

  /// Initialisation period during which failed checks are not counted, in
  /// nanoseconds.
  final int? startPeriod;

  /// Interval for health checks during the start period, in nanoseconds.
  final int? startInterval;

  /// Creates a [ContainerHealthcheck] with the given fields.
  const ContainerHealthcheck({
    this.test,
    this.interval,
    this.timeout,
    this.retries,
    this.startPeriod,
    this.startInterval,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerHealthcheck.fromJson(Map<String, dynamic> json) =>
      ContainerHealthcheck(
        test: (json['Test'] as List<dynamic>?)?.cast<String>(),
        interval: json['Interval'] as int?,
        timeout: json['Timeout'] as int?,
        retries: json['Retries'] as int?,
        startPeriod: json['StartPeriod'] as int?,
        startInterval: json['StartInterval'] as int?,
      );
}

/// The container-level configuration as stored in the image or overridden at
/// run time.
///
/// This corresponds to Docker's `Config` sub-object in the inspect response.
class ContainerConfig {
  /// Hostname set inside the container.
  final String? hostname;

  /// Domain name set inside the container.
  final String? domainname;

  /// User that runs the container's main process.
  final String? user;

  /// Whether stdin is attached at container creation.
  final bool? attachStdin;

  /// Whether stdout is attached.
  final bool? attachStdout;

  /// Whether stderr is attached.
  final bool? attachStderr;

  /// Ports that the container exposes. Keys are `'port/proto'` strings;
  /// values are always empty objects `{}`.
  final Map<String, dynamic>? exposedPorts;

  /// Whether a pseudo-TTY is allocated for the container.
  final bool? tty;

  /// Whether stdin is kept open even if not attached.
  final bool? openStdin;

  /// Whether stdin is closed after one attach.
  final bool? stdinOnce;

  /// Environment variables as `KEY=value` strings.
  final List<String>? env;

  /// Default command run by the container.
  final List<String>? cmd;

  /// Health-check configuration embedded in the image.
  final ContainerHealthcheck? healthcheck;

  /// Windows-only: whether shell argument escaping is applied to [cmd].
  final bool? argsEscaped;

  /// Image name or ID that the container was created from.
  final String? image;

  /// Volume mount points declared in the image. Keys are container paths;
  /// values are always empty objects.
  final Map<String, dynamic>? volumes;

  /// Working directory for the container's main process.
  final String? workingDir;

  /// Entrypoint command.
  final List<String>? entrypoint;

  /// Whether networking is disabled for the container.
  final bool? networkDisabled;

  /// MAC address of the container's primary network interface (legacy field).
  final String? macAddress;

  /// List of `ONBUILD` trigger instructions.
  final List<String>? onBuild;

  /// Labels applied to the container.
  final Map<String, String>? labels;

  /// Signal to send to the main process to stop the container
  /// (e.g. `'SIGTERM'`).
  final String? stopSignal;

  /// Timeout in seconds before a SIGKILL is sent after [stopSignal].
  final int? stopTimeout;

  /// Shell used for shell-form `CMD`/`RUN` instructions.
  final List<String>? shell;

  /// Creates a [ContainerConfig] with the given fields.
  const ContainerConfig({
    this.hostname,
    this.domainname,
    this.user,
    this.attachStdin,
    this.attachStdout,
    this.attachStderr,
    this.exposedPorts,
    this.tty,
    this.openStdin,
    this.stdinOnce,
    this.env,
    this.cmd,
    this.healthcheck,
    this.argsEscaped,
    this.image,
    this.volumes,
    this.workingDir,
    this.entrypoint,
    this.networkDisabled,
    this.macAddress,
    this.onBuild,
    this.labels,
    this.stopSignal,
    this.stopTimeout,
    this.shell,
  });

  /// Deserialises a [ContainerConfig] from Docker's JSON representation.
  factory ContainerConfig.fromJson(Map<String, dynamic> json) {
    final hcData = json['Healthcheck'] as Map<String, dynamic>?;
    return ContainerConfig(
      hostname: json['Hostname'] as String?,
      domainname: json['Domainname'] as String?,
      user: json['User'] as String?,
      attachStdin: json['AttachStdin'] as bool?,
      attachStdout: json['AttachStdout'] as bool?,
      attachStderr: json['AttachStderr'] as bool?,
      exposedPorts: json['ExposedPorts'] as Map<String, dynamic>?,
      tty: json['Tty'] as bool?,
      openStdin: json['OpenStdin'] as bool?,
      stdinOnce: json['StdinOnce'] as bool?,
      env: (json['Env'] as List<dynamic>?)?.cast<String>(),
      cmd: (json['Cmd'] as List<dynamic>?)?.cast<String>(),
      healthcheck:
          hcData != null ? ContainerHealthcheck.fromJson(hcData) : null,
      argsEscaped: json['ArgsEscaped'] as bool?,
      image: json['Image'] as String?,
      volumes: json['Volumes'] as Map<String, dynamic>?,
      workingDir: json['WorkingDir'] as String?,
      entrypoint: (json['Entrypoint'] as List<dynamic>?)?.cast<String>(),
      networkDisabled: json['NetworkDisabled'] as bool?,
      macAddress: json['MacAddress'] as String?,
      onBuild: (json['OnBuild'] as List<dynamic>?)?.cast<String>(),
      labels: (json['Labels'] as Map<String, dynamic>?)?.cast<String, String>(),
      stopSignal: json['StopSignal'] as String?,
      stopTimeout: json['StopTimeout'] as int?,
      shell: (json['Shell'] as List<dynamic>?)?.cast<String>(),
    );
  }
}

/// Static IP configuration for a network endpoint (IPAM).
class ContainerIPAMConfig {
  /// Statically assigned IPv4 address.
  final String? ipv4Address;

  /// Statically assigned IPv6 address.
  final String? ipv6Address;

  /// Link-local IP addresses.
  final List<String>? linkLocalIPs;

  /// Creates a [ContainerIPAMConfig] with the given fields.
  const ContainerIPAMConfig({
    this.ipv4Address,
    this.ipv6Address,
    this.linkLocalIPs,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerIPAMConfig.fromJson(Map<String, dynamic> json) =>
      ContainerIPAMConfig(
        ipv4Address: json['IPv4Address'] as String?,
        ipv6Address: json['IPv6Address'] as String?,
        linkLocalIPs: (json['LinkLocalIPs'] as List<dynamic>?)?.cast<String>(),
      );
}

/// A container's connection details on a single Docker network.
class ContainerNetworkEndpoint {
  /// Static IP assignment configuration.
  final ContainerIPAMConfig? ipamConfig;

  /// Linked container names (legacy `--link` feature).
  final List<String>? links;

  /// MAC address of this network interface.
  final String? macAddress;

  /// DNS aliases for this container on this network.
  final List<String>? aliases;

  /// Driver-specific options for this endpoint.
  final Map<String, String>? driverOpts;

  /// Gateway priority for this endpoint (Docker 25+ field).
  final int? gwPriority;

  /// Docker network ID.
  final String? networkID;

  /// Endpoint ID within the network.
  final String? endpointID;

  /// Gateway IP address for this network.
  final String? gateway;

  /// IPv4 address assigned to the container on this network.
  final String? ipAddress;

  /// Prefix length of the IPv4 subnet.
  final int? ipPrefixLen;

  /// IPv6 gateway address.
  final String? ipv6Gateway;

  /// Global IPv6 address.
  final String? globalIPv6Address;

  /// Prefix length of the global IPv6 address.
  final int? globalIPv6PrefixLen;

  /// DNS names by which this container can be reached (Docker 25+).
  final List<String>? dnsNames;

  /// Creates a [ContainerNetworkEndpoint] with the given fields.
  const ContainerNetworkEndpoint({
    this.ipamConfig,
    this.links,
    this.macAddress,
    this.aliases,
    this.driverOpts,
    this.gwPriority,
    this.networkID,
    this.endpointID,
    this.gateway,
    this.ipAddress,
    this.ipPrefixLen,
    this.ipv6Gateway,
    this.globalIPv6Address,
    this.globalIPv6PrefixLen,
    this.dnsNames,
  });

  /// Deserialises from Docker's JSON representation.
  factory ContainerNetworkEndpoint.fromJson(Map<String, dynamic> json) {
    final ipamData = json['IPAMConfig'] as Map<String, dynamic>?;
    return ContainerNetworkEndpoint(
      ipamConfig:
          ipamData != null ? ContainerIPAMConfig.fromJson(ipamData) : null,
      links: (json['Links'] as List<dynamic>?)?.cast<String>(),
      macAddress: json['MacAddress'] as String?,
      aliases: (json['Aliases'] as List<dynamic>?)?.cast<String>(),
      driverOpts:
          (json['DriverOpts'] as Map<String, dynamic>?)?.cast<String, String>(),
      gwPriority: json['GwPriority'] as int?,
      networkID: json['NetworkID'] as String?,
      endpointID: json['EndpointID'] as String?,
      gateway: json['Gateway'] as String?,
      ipAddress: json['IPAddress'] as String?,
      ipPrefixLen: json['IPPrefixLen'] as int?,
      ipv6Gateway: json['IPv6Gateway'] as String?,
      globalIPv6Address: json['GlobalIPv6Address'] as String?,
      globalIPv6PrefixLen: json['GlobalIPv6PrefixLen'] as int?,
      dnsNames: (json['DNSNames'] as List<dynamic>?)?.cast<String>(),
    );
  }
}

/// A single IP address assigned to a container's secondary network interface.
class ContainerAddress {
  /// IP address string.
  final String? addr;

  /// Subnet prefix length.
  final int? prefixLen;

  /// Creates a [ContainerAddress] with the given fields.
  const ContainerAddress({this.addr, this.prefixLen});

  /// Deserialises from Docker's JSON representation.
  factory ContainerAddress.fromJson(Map<String, dynamic> json) =>
      ContainerAddress(
        addr: json['Addr'] as String?,
        prefixLen: json['PrefixLen'] as int?,
      );
}

/// The complete network configuration of a running container.
///
/// Returned as the `NetworkSettings` field in a container inspect response.
class ContainerNetworkSettings {
  /// Name of the default bridge network.
  final String? bridge;

  /// Sandbox ID (internal identifier for the network namespace).
  final String? sandboxID;

  /// Whether hairpin NAT is enabled.
  final bool? hairpinMode;

  /// Link-local IPv6 address.
  final String? linkLocalIPv6Address;

  /// Prefix length of the link-local IPv6 address.
  final String? linkLocalIPv6PrefixLen;

  /// Published port bindings: container port spec → list of host bindings.
  final Map<String, List<ContainerPortBinding>?>? ports;

  /// Sandbox key (path to the network namespace file).
  final String? sandboxKey;

  /// Secondary IPv4 addresses.
  final List<ContainerAddress>? secondaryIPAddresses;

  /// Secondary IPv6 addresses.
  final List<ContainerAddress>? secondaryIPv6Addresses;

  /// Default network endpoint ID.
  final String? endpointID;

  /// Default network gateway IP.
  final String? gateway;

  /// Global IPv6 address on the default network.
  final String? globalIPv6Address;

  /// Prefix length of the global IPv6 address.
  final int? globalIPv6PrefixLen;

  /// IPv4 address on the default network.
  final String? ipAddress;

  /// Prefix length of the IPv4 address.
  final int? ipPrefixLen;

  /// IPv6 gateway on the default network.
  final String? ipv6Gateway;

  /// MAC address on the default network.
  final String? macAddress;

  /// Per-network connection details, keyed by network name.
  final Map<String, ContainerNetworkEndpoint>? networks;

  /// Creates a [ContainerNetworkSettings] with the given fields.
  const ContainerNetworkSettings({
    this.bridge,
    this.sandboxID,
    this.hairpinMode,
    this.linkLocalIPv6Address,
    this.linkLocalIPv6PrefixLen,
    this.ports,
    this.sandboxKey,
    this.secondaryIPAddresses,
    this.secondaryIPv6Addresses,
    this.endpointID,
    this.gateway,
    this.globalIPv6Address,
    this.globalIPv6PrefixLen,
    this.ipAddress,
    this.ipPrefixLen,
    this.ipv6Gateway,
    this.macAddress,
    this.networks,
  });

  /// Deserialises a [ContainerNetworkSettings] from Docker's JSON
  /// representation.
  factory ContainerNetworkSettings.fromJson(Map<String, dynamic> json) {
    Map<String, List<ContainerPortBinding>?>? ports;
    final rawPorts = json['Ports'] as Map<String, dynamic>?;
    if (rawPorts != null) {
      ports = {};
      for (final entry in rawPorts.entries) {
        final bindings = entry.value as List<dynamic>?;
        ports[entry.key] = bindings
            ?.map(
              (b) => ContainerPortBinding.fromJson(b as Map<String, dynamic>),
            )
            .toList();
      }
    }

    Map<String, ContainerNetworkEndpoint>? networks;
    final rawNetworks = json['Networks'] as Map<String, dynamic>?;
    if (rawNetworks != null) {
      networks = {};
      for (final entry in rawNetworks.entries) {
        networks[entry.key] = ContainerNetworkEndpoint.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    List<ContainerAddress>? parseAddresses(dynamic raw) {
      return (raw as List<dynamic>?)
          ?.map((e) => ContainerAddress.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return ContainerNetworkSettings(
      bridge: json['Bridge'] as String?,
      sandboxID: json['SandboxID'] as String?,
      hairpinMode: json['HairpinMode'] as bool?,
      linkLocalIPv6Address: json['LinkLocalIPv6Address'] as String?,
      linkLocalIPv6PrefixLen: json['LinkLocalIPv6PrefixLen'] as String?,
      ports: ports,
      sandboxKey: json['SandboxKey'] as String?,
      secondaryIPAddresses: parseAddresses(json['SecondaryIPAddresses']),
      secondaryIPv6Addresses: parseAddresses(json['SecondaryIPv6Addresses']),
      endpointID: json['EndpointID'] as String?,
      gateway: json['Gateway'] as String?,
      globalIPv6Address: json['GlobalIPv6Address'] as String?,
      globalIPv6PrefixLen: json['GlobalIPv6PrefixLen'] as int?,
      ipAddress: json['IPAddress'] as String?,
      ipPrefixLen: json['IPPrefixLen'] as int?,
      ipv6Gateway: json['IPv6Gateway'] as String?,
      macAddress: json['MacAddress'] as String?,
      networks: networks,
    );
  }
}

/// The complete inspect response for a single Docker container.
///
/// Returned by [DockerClient.containerInspectInfo] and by
/// `ComposeContainer.containerInfo`. All fields are optional — Docker's
/// API may omit fields depending on the daemon version and container state.
class ContainerInspectInfo {
  /// Full container ID (64-character hex string).
  final String? id;

  /// RFC 3339 timestamp when the container was created.
  final String? created;

  /// Entrypoint or command path.
  final String? path;

  /// Arguments passed to [path].
  final List<String>? args;

  /// Current lifecycle and health state.
  final ContainerState? state;

  /// Image ID (`sha256:…`) that the container was created from.
  final String? image;

  /// Path to the `resolv.conf` file on the host.
  final String? resolvConfPath;

  /// Path to the container's hostname file on the host.
  final String? hostnamePath;

  /// Path to the container's `/etc/hosts` file on the host.
  final String? hostsPath;

  /// Path to the container's log file on the host.
  final String? logPath;

  /// Container name (prefixed with `/`, e.g. `'/myapp'`).
  final String? name;

  /// Number of times the container has been restarted.
  final int? restartCount;

  /// Storage driver used for the container's writable layer.
  final String? driver;

  /// Platform (OS) the container is running on.
  final String? platform;

  /// OCI image manifest descriptor (present on Docker 25+ for multi-arch
  /// images).
  final ContainerImageManifestDescriptor? imageManifestDescriptor;

  /// SELinux label applied to the container's mounts.
  final String? mountLabel;

  /// SELinux label applied to the container process.
  final String? processLabel;

  /// AppArmor profile applied to the container.
  final String? appArmorProfile;

  /// List of exec IDs currently running inside the container.
  final List<String>? execIDs;

  /// Host-level resource and runtime configuration.
  final ContainerHostConfig? hostConfig;

  /// Storage driver metadata for the container's layers.
  final ContainerGraphDriver? graphDriver;

  /// Size of the container's writable layer in bytes (may be a string in
  /// older Docker versions).
  final String? sizeRw;

  /// Total size of all image layers in bytes.
  final String? sizeRootFs;

  /// Active volume and bind mounts.
  final List<ContainerMount>? mounts;

  /// Image-level and runtime configuration.
  final ContainerConfig? config;

  /// Network state and per-network connection details.
  final ContainerNetworkSettings? networkSettings;

  /// Creates a [ContainerInspectInfo] with the given fields.
  const ContainerInspectInfo({
    this.id,
    this.created,
    this.path,
    this.args,
    this.state,
    this.image,
    this.resolvConfPath,
    this.hostnamePath,
    this.hostsPath,
    this.logPath,
    this.name,
    this.restartCount,
    this.driver,
    this.platform,
    this.imageManifestDescriptor,
    this.mountLabel,
    this.processLabel,
    this.appArmorProfile,
    this.execIDs,
    this.hostConfig,
    this.graphDriver,
    this.sizeRw,
    this.sizeRootFs,
    this.mounts,
    this.config,
    this.networkSettings,
  });

  /// Deserialises a [ContainerInspectInfo] from the raw JSON map returned by
  /// `GET /containers/{id}/json`.
  factory ContainerInspectInfo.fromJson(Map<String, dynamic> json) {
    final stateData = json['State'] as Map<String, dynamic>?;
    final hostConfigData = json['HostConfig'] as Map<String, dynamic>?;
    final graphDriverData = json['GraphDriver'] as Map<String, dynamic>?;
    final configData = json['Config'] as Map<String, dynamic>?;
    final networkSettingsData =
        json['NetworkSettings'] as Map<String, dynamic>?;
    final imageManifestData =
        json['ImageManifestDescriptor'] as Map<String, dynamic>?;

    return ContainerInspectInfo(
      id: json['Id'] as String?,
      created: json['Created'] as String?,
      path: json['Path'] as String?,
      args: (json['Args'] as List<dynamic>?)?.cast<String>(),
      state: stateData != null ? ContainerState.fromJson(stateData) : null,
      image: json['Image'] as String?,
      resolvConfPath: json['ResolvConfPath'] as String?,
      hostnamePath: json['HostnamePath'] as String?,
      hostsPath: json['HostsPath'] as String?,
      logPath: json['LogPath'] as String?,
      name: json['Name'] as String?,
      restartCount: json['RestartCount'] as int?,
      driver: json['Driver'] as String?,
      platform: json['Platform'] as String?,
      imageManifestDescriptor: imageManifestData != null
          ? ContainerImageManifestDescriptor.fromJson(imageManifestData)
          : null,
      mountLabel: json['MountLabel'] as String?,
      processLabel: json['ProcessLabel'] as String?,
      appArmorProfile: json['AppArmorProfile'] as String?,
      execIDs: (json['ExecIDs'] as List<dynamic>?)?.cast<String>(),
      hostConfig: hostConfigData != null
          ? ContainerHostConfig.fromJson(hostConfigData)
          : null,
      graphDriver: graphDriverData != null
          ? ContainerGraphDriver.fromJson(graphDriverData)
          : null,
      sizeRw: json['SizeRw']?.toString(),
      sizeRootFs: json['SizeRootFs']?.toString(),
      mounts: (json['Mounts'] as List<dynamic>?)
          ?.map((e) => ContainerMount.fromJson(e as Map<String, dynamic>))
          .toList(),
      config: configData != null ? ContainerConfig.fromJson(configData) : null,
      networkSettings: networkSettingsData != null
          ? ContainerNetworkSettings.fromJson(networkSettingsData)
          : null,
    );
  }
}
