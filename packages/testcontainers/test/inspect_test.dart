@Tags(['unit'])
library;

import 'package:test/test.dart';
import 'package:testcontainers/src/inspect.dart';

void main() {
  group('ContainerInspectInfo.fromJson', () {
    final sampleJson = {
      'Id': 'abc123def456',
      'Created': '2024-01-01T00:00:00Z',
      'Name': '/my-container',
      'Image': 'sha256:deadbeef',
      'Platform': 'linux',
      'State': {
        'Status': 'running',
        'Running': true,
        'Paused': false,
        'Restarting': false,
        'OOMKilled': false,
        'Dead': false,
        'Pid': 1234,
        'ExitCode': 0,
        'Error': '',
        'StartedAt': '2024-01-01T00:00:01Z',
        'FinishedAt': '0001-01-01T00:00:00Z',
      },
      'Config': {
        'Hostname': 'abc123de',
        'Image': 'nginx:alpine',
        'Labels': {'app': 'test'},
        'Env': ['PATH=/usr/local/sbin:/usr/local/bin'],
      },
      'NetworkSettings': {
        'Bridge': '',
        'IPAddress': '172.17.0.2',
        'Gateway': '172.17.0.1',
        'Networks': {
          'bridge': {
            'NetworkID': 'net123',
            'Gateway': '172.17.0.1',
            'IPAddress': '172.17.0.2',
            'IPPrefixLen': 16,
          },
        },
      },
      'HostConfig': {
        'NetworkMode': 'bridge',
        'PortBindings': {
          '80/tcp': [
            {'HostIp': '0.0.0.0', 'HostPort': '32768'},
          ],
        },
      },
      'Mounts': [],
    };

    test('parses Id and Name', () {
      final info = ContainerInspectInfo.fromJson(sampleJson);
      expect(info.id, equals('abc123def456'));
      expect(info.name, equals('/my-container'));
    });

    test('parses State', () {
      final info = ContainerInspectInfo.fromJson(sampleJson);
      expect(info.state, isNotNull);
      expect(info.state!.status, equals('running'));
      expect(info.state!.running, isTrue);
      expect(info.state!.pid, equals(1234));
    });

    test('parses Config', () {
      final info = ContainerInspectInfo.fromJson(sampleJson);
      expect(info.config, isNotNull);
      expect(info.config!.image, equals('nginx:alpine'));
      expect(info.config!.labels, equals({'app': 'test'}));
    });

    test('parses NetworkSettings', () {
      final info = ContainerInspectInfo.fromJson(sampleJson);
      final ns = info.networkSettings;
      expect(ns, isNotNull);
      expect(ns!.networks, isNotNull);
      expect(ns.networks!.containsKey('bridge'), isTrue);
      final bridge = ns.networks!['bridge']!;
      expect(bridge.ipAddress, equals('172.17.0.2'));
      expect(bridge.gateway, equals('172.17.0.1'));
      expect(bridge.networkID, equals('net123'));
    });

    test('parses HostConfig PortBindings', () {
      final info = ContainerInspectInfo.fromJson(sampleJson);
      expect(info.hostConfig, isNotNull);
      final bindings = info.hostConfig!.portBindings;
      expect(bindings, isNotNull);
      expect(bindings!.containsKey('80/tcp'), isTrue);
      final binding = bindings['80/tcp']!.first;
      expect(binding.hostPort, equals('32768'));
    });

    test('survives unknown JSON keys', () {
      final json = Map<String, dynamic>.from(sampleJson);
      json['UnknownField'] = 'ignored';
      expect(() => ContainerInspectInfo.fromJson(json), returnsNormally);
    });

    test('handles null/missing optional fields', () {
      final info = ContainerInspectInfo.fromJson({});
      expect(info.id, isNull);
      expect(info.state, isNull);
      expect(info.config, isNull);
    });
  });

  group('ContainerHealth', () {
    test('parses health status', () {
      final health = ContainerHealth.fromJson({
        'Status': 'healthy',
        'FailingStreak': 0,
        'Log': [],
      });
      expect(health.status, equals('healthy'));
      expect(health.failingStreak, equals(0));
    });

    test('parses health log entries', () {
      final health = ContainerHealth.fromJson({
        'Status': 'healthy',
        'FailingStreak': 0,
        'Log': [
          {'Output': 'healthy', 'ExitCode': 0},
        ],
      });
      expect(health.log, isNotNull);
      expect(health.log!.length, equals(1));
      expect(health.log!.first.output, equals('healthy'));
      expect(health.log!.first.exitCode, equals(0));
    });
  });

  group('ContainerNetworkEndpoint', () {
    test('parses basic fields', () {
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net456',
        'IPAddress': '10.0.0.2',
        'Gateway': '10.0.0.1',
        'IPPrefixLen': 24,
      });
      expect(endpoint.networkID, equals('net456'));
      expect(endpoint.ipAddress, equals('10.0.0.2'));
      expect(endpoint.gateway, equals('10.0.0.1'));
    });

    test('parses macAddress and aliases', () {
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net123',
        'IPAddress': '172.17.0.3',
        'Gateway': '172.17.0.1',
        'MacAddress': '02:42:ac:11:00:03',
        'Aliases': ['container-alias'],
      });
      expect(endpoint.macAddress, equals('02:42:ac:11:00:03'));
      expect(endpoint.aliases, equals(['container-alias']));
    });

    test('parses nested IPAMConfig', () {
      // IPAMConfig is present when the container uses a static IP address.
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net789',
        'IPAddress': '10.0.0.5',
        'Gateway': '10.0.0.1',
        'IPAMConfig': {
          'IPv4Address': '10.0.0.5',
          'IPv6Address': '',
          'LinkLocalIPs': ['169.254.0.1'],
        },
      });
      expect(endpoint.ipamConfig, isNotNull);
      expect(endpoint.ipamConfig!.ipv4Address, equals('10.0.0.5'));
      expect(endpoint.ipamConfig!.linkLocalIPs, equals(['169.254.0.1']));
    });

    test('ipamConfig is null when IPAMConfig key is absent', () {
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net000',
        'IPAddress': '172.17.0.4',
        'Gateway': '172.17.0.1',
      });
      expect(endpoint.ipamConfig, isNull);
    });

    test('parses dnsNames (Docker 25+)', () {
      // DNSNames was added in Docker Engine 25 for DNS-based service discovery.
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net456',
        'IPAddress': '192.168.1.2',
        'Gateway': '192.168.1.1',
        'DNSNames': ['web', 'web.mynetwork'],
      });
      expect(endpoint.dnsNames, equals(['web', 'web.mynetwork']));
    });

    test('parses driverOpts map', () {
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net_ovl',
        'IPAddress': '10.1.0.2',
        'Gateway': '10.1.0.1',
        'DriverOpts': {'com.docker.network.driver.overlay.vxlanid': '4097'},
      });
      expect(endpoint.driverOpts, isNotNull);
      expect(
        endpoint.driverOpts!['com.docker.network.driver.overlay.vxlanid'],
        equals('4097'),
      );
    });
  });

  group('ContainerConfig', () {
    test('parses cmd and exposedPorts', () {
      final config = ContainerConfig.fromJson({
        'Image': 'nginx:alpine',
        'Hostname': 'my-hostname',
        'Env': ['PATH=/usr/bin', 'HOME=/root'],
        'Cmd': ['nginx', '-g', 'daemon off;'],
        'ExposedPorts': {'80/tcp': <String, dynamic>{}},
      });
      expect(config.cmd, equals(['nginx', '-g', 'daemon off;']));
      expect(config.exposedPorts, isNotNull);
      expect(config.exposedPorts!.containsKey('80/tcp'), isTrue);
      expect(config.env, equals(['PATH=/usr/bin', 'HOME=/root']));
    });

    test('parses nested Healthcheck object', () {
      // ContainerConfig.fromJson must delegate to ContainerHealthcheck.fromJson.
      final config = ContainerConfig.fromJson({
        'Image': 'nginx:alpine',
        'Hostname': 'h',
        'Healthcheck': {
          'Test': ['CMD', 'curl', '-f', 'http://localhost/'],
          'Interval': 30000000000,
          'Timeout': 10000000000,
          'Retries': 3,
          'StartPeriod': 5000000000,
        },
      });
      expect(config.healthcheck, isNotNull);
      expect(
        config.healthcheck!.test,
        equals(['CMD', 'curl', '-f', 'http://localhost/']),
      );
      expect(config.healthcheck!.interval, equals(30000000000));
      expect(config.healthcheck!.retries, equals(3));
    });

    test('healthcheck is null when Healthcheck key is absent', () {
      final config = ContainerConfig.fromJson({'Image': 'alpine', 'Hostname': 'h'});
      expect(config.healthcheck, isNull);
    });

    test('parses workingDir and entrypoint', () {
      final config = ContainerConfig.fromJson({
        'Image': 'node:lts',
        'Hostname': 'h',
        'WorkingDir': '/app',
        'Entrypoint': ['node', 'server.js'],
      });
      expect(config.workingDir, equals('/app'));
      expect(config.entrypoint, equals(['node', 'server.js']));
    });
  });

  group('ContainerHealthcheck', () {
    test('fromJson parses all fields', () {
      final hc = ContainerHealthcheck.fromJson({
        'Test': ['CMD-SHELL', 'curl -f http://localhost/ || exit 1'],
        'Interval': 30000000000,
        'Timeout': 10000000000,
        'Retries': 5,
        'StartPeriod': 15000000000,
        'StartInterval': 2000000000,
      });
      expect(hc.test, equals(['CMD-SHELL', 'curl -f http://localhost/ || exit 1']));
      expect(hc.interval, equals(30000000000));
      expect(hc.timeout, equals(10000000000));
      expect(hc.retries, equals(5));
      expect(hc.startPeriod, equals(15000000000));
      expect(hc.startInterval, equals(2000000000));
    });

    test('fromJson handles NONE test type', () {
      final hc = ContainerHealthcheck.fromJson({
        'Test': ['NONE'],
      });
      expect(hc.test, equals(['NONE']));
      expect(hc.interval, isNull);
    });

    test('fromJson tolerates missing fields', () {
      final hc = ContainerHealthcheck.fromJson({});
      expect(hc.test, isNull);
      expect(hc.retries, isNull);
      expect(hc.startInterval, isNull);
    });
  });

  group('ContainerHostConfig', () {
    test('parses memory and cpuShares', () {
      final hostConfig = ContainerHostConfig.fromJson({
        'Memory': 1073741824,
        'CpuShares': 1024,
        'NetworkMode': 'bridge',
      });
      expect(hostConfig.memory, equals(1073741824));
      expect(hostConfig.cpuShares, equals(1024));
      expect(hostConfig.networkMode, equals('bridge'));
    });
  });

  // ---------------------------------------------------------------------------
  // ContainerHostConfig — comprehensive coverage of all field categories
  // ---------------------------------------------------------------------------
  group('ContainerHostConfig nested fields', () {
    test('parses ulimits list', () {
      final hc = ContainerHostConfig.fromJson({
        'Ulimits': [
          {'Name': 'nofile', 'Soft': 1024, 'Hard': 4096},
          {'Name': 'nproc', 'Soft': 512, 'Hard': 1024},
        ],
      });
      expect(hc.ulimits, isNotNull);
      expect(hc.ulimits!.length, equals(2));
      expect(hc.ulimits![0].name, equals('nofile'));
      expect(hc.ulimits![0].soft, equals(1024));
      expect(hc.ulimits![0].hard, equals(4096));
      expect(hc.ulimits![1].name, equals('nproc'));
    });

    test('parses devices list', () {
      final hc = ContainerHostConfig.fromJson({
        'Devices': [
          {
            'PathOnHost': '/dev/ttyUSB0',
            'PathInContainer': '/dev/ttyUSB0',
            'CgroupPermissions': 'rwm',
          },
        ],
      });
      expect(hc.devices, isNotNull);
      expect(hc.devices!.length, equals(1));
      expect(hc.devices!.first.pathOnHost, equals('/dev/ttyUSB0'));
      expect(hc.devices!.first.cgroupPermissions, equals('rwm'));
    });

    test('parses deviceRequests list (GPU)', () {
      final hc = ContainerHostConfig.fromJson({
        'DeviceRequests': [
          {
            'Driver': 'nvidia',
            'Count': -1,
            'DeviceIDs': ['0'],
            'Capabilities': [
              ['gpu'],
            ],
            'Options': <String, dynamic>{},
          },
        ],
      });
      expect(hc.deviceRequests, isNotNull);
      expect(hc.deviceRequests!.first.driver, equals('nvidia'));
      expect(hc.deviceRequests!.first.count, equals(-1));
      expect(hc.deviceRequests!.first.deviceIDs, equals(['0']));
    });

    test('parses blkioWeightDevice list', () {
      final hc = ContainerHostConfig.fromJson({
        'BlkioWeightDevice': [
          {'Path': '/dev/sda', 'Weight': 500},
        ],
      });
      expect(hc.blkioWeightDevice, isNotNull);
      expect(hc.blkioWeightDevice!.first.path, equals('/dev/sda'));
      expect(hc.blkioWeightDevice!.first.weight, equals(500));
    });

    test('parses all four blkio device rate lists', () {
      final hc = ContainerHostConfig.fromJson({
        'BlkioDeviceReadBps': [
          {'Path': '/dev/sda', 'Rate': 104857600},
        ],
        'BlkioDeviceWriteBps': [
          {'Path': '/dev/sda', 'Rate': 52428800},
        ],
        'BlkioDeviceReadIOps': [
          {'Path': '/dev/sda', 'Rate': 1000},
        ],
        'BlkioDeviceWriteIOps': [
          {'Path': '/dev/sda', 'Rate': 500},
        ],
      });
      expect(hc.blkioDeviceReadBps!.first.rate, equals(104857600));
      expect(hc.blkioDeviceWriteBps!.first.rate, equals(52428800));
      expect(hc.blkioDeviceReadIOps!.first.rate, equals(1000));
      expect(hc.blkioDeviceWriteIOps!.first.rate, equals(500));
    });

    test('parses portBindings — published and null (exposed-but-not-bound)', () {
      // PortBindings in HostConfig mirrors ContainerNetworkSettings.Ports:
      // a null value means the port is EXPOSE-d but not -p published.
      final hc = ContainerHostConfig.fromJson({
        'PortBindings': {
          '80/tcp': [
            {'HostIp': '0.0.0.0', 'HostPort': '32768'},
          ],
          '443/tcp': null,
        },
      });
      expect(hc.portBindings, isNotNull);
      expect(hc.portBindings!['80/tcp']!.first.hostPort, equals('32768'));
      expect(hc.portBindings!['80/tcp']!.first.hostIp, equals('0.0.0.0'));
      expect(hc.portBindings!['443/tcp'], isNull);
    });

    test('portBindings is null when PortBindings key is absent', () {
      final hc = ContainerHostConfig.fromJson({'NetworkMode': 'bridge'});
      expect(hc.portBindings, isNull);
    });

    test('portBindings with empty map produces empty portBindings', () {
      final hc = ContainerHostConfig.fromJson({
        'PortBindings': <String, dynamic>{},
      });
      expect(hc.portBindings, isNotNull);
      expect(hc.portBindings!, isEmpty);
    });

    test('parses nested logConfig', () {
      final hc = ContainerHostConfig.fromJson({
        'LogConfig': {
          'Type': 'json-file',
          'Config': {'max-size': '10m', 'max-file': '5'},
        },
      });
      expect(hc.logConfig, isNotNull);
      expect(hc.logConfig!.type, equals('json-file'));
      expect(hc.logConfig!.config!['max-size'], equals('10m'));
    });

    test('logConfig is null when LogConfig key is absent', () {
      final hc = ContainerHostConfig.fromJson({});
      expect(hc.logConfig, isNull);
    });

    test('parses nested restartPolicy', () {
      final hc = ContainerHostConfig.fromJson({
        'RestartPolicy': {'Name': 'on-failure', 'MaximumRetryCount': 5},
      });
      expect(hc.restartPolicy, isNotNull);
      expect(hc.restartPolicy!.name, equals('on-failure'));
      expect(hc.restartPolicy!.maximumRetryCount, equals(5));
    });

    test('restartPolicy is null when RestartPolicy key is absent', () {
      final hc = ContainerHostConfig.fromJson({});
      expect(hc.restartPolicy, isNull);
    });

    test('parses mounts list (ContainerMountPoint entries)', () {
      final hc = ContainerHostConfig.fromJson({
        'Mounts': [
          {
            'Type': 'bind',
            'Source': '/host/data',
            'Target': '/data',
            'ReadOnly': false,
          },
          {
            'Type': 'volume',
            'Source': '/var/lib/docker/volumes/vol/_data',
            'Target': '/vol',
            'ReadOnly': true,
          },
        ],
      });
      expect(hc.mounts, isNotNull);
      expect(hc.mounts!.length, equals(2));
      expect(hc.mounts![0].type, equals('bind'));
      expect(hc.mounts![0].source, equals('/host/data'));
      expect(hc.mounts![1].readOnly, isTrue);
    });

    test('parses boolean flags', () {
      final hc = ContainerHostConfig.fromJson({
        'Privileged': true,
        'AutoRemove': true,
        'ReadonlyRootfs': true,
        'PublishAllPorts': false,
        'OomKillDisable': false,
        'Init': true,
      });
      expect(hc.privileged, isTrue);
      expect(hc.autoRemove, isTrue);
      expect(hc.readonlyRootfs, isTrue);
      expect(hc.publishAllPorts, isFalse);
      expect(hc.oomKillDisable, isFalse);
      expect(hc.init, isTrue);
    });

    test('parses string list fields', () {
      final hc = ContainerHostConfig.fromJson({
        'CapAdd': ['NET_ADMIN', 'SYS_PTRACE'],
        'CapDrop': ['MKNOD'],
        'Dns': ['8.8.8.8', '8.8.4.4'],
        'DnsSearch': ['example.com'],
        'DnsOptions': ['ndots:5'],
        'ExtraHosts': ['host.docker.internal:host-gateway'],
        'Binds': ['/host:/container:rw'],
        'VolumesFrom': ['other-container:ro'],
        'SecurityOpt': ['no-new-privileges:true'],
        'MaskedPaths': ['/proc/kcore'],
        'ReadonlyPaths': ['/proc/asound'],
        'DeviceCgroupRules': ['c 136:* rwm'],
        'GroupAdd': ['audio'],
        'Links': <String>[],
      });
      expect(hc.capAdd, equals(['NET_ADMIN', 'SYS_PTRACE']));
      expect(hc.capDrop, equals(['MKNOD']));
      expect(hc.dns, equals(['8.8.8.8', '8.8.4.4']));
      expect(hc.dnsSearch, equals(['example.com']));
      expect(hc.dnsOptions, equals(['ndots:5']));
      expect(hc.extraHosts, equals(['host.docker.internal:host-gateway']));
      expect(hc.binds, equals(['/host:/container:rw']));
      expect(hc.volumesFrom, equals(['other-container:ro']));
      expect(hc.securityOpt, equals(['no-new-privileges:true']));
      expect(hc.maskedPaths, equals(['/proc/kcore']));
      expect(hc.readonlyPaths, equals(['/proc/asound']));
      expect(hc.deviceCgroupRules, equals(['c 136:* rwm']));
      expect(hc.groupAdd, equals(['audio']));
      expect(hc.links, isEmpty);
    });

    test('parses map fields', () {
      final hc = ContainerHostConfig.fromJson({
        'Sysctls': {
          'net.ipv4.ip_forward': '1',
          'net.core.somaxconn': '1024',
        },
        'Tmpfs': {'/tmp': 'size=64m,mode=1777'},
        'StorageOpt': {'size': '10G'},
        'Annotations': {'com.example.note': 'test-run'},
      });
      expect(
        hc.sysctls,
        equals({
          'net.ipv4.ip_forward': '1',
          'net.core.somaxconn': '1024',
        }),
      );
      expect(hc.tmpfs, equals({'/tmp': 'size=64m,mode=1777'}));
      expect(hc.storageOpt, equals({'size': '10G'}));
      expect(hc.annotations, equals({'com.example.note': 'test-run'}));
    });

    test('parses CPU and memory limit integers', () {
      final hc = ContainerHostConfig.fromJson({
        'CpuPeriod': 100000,
        'CpuQuota': 50000,
        'CpuRealtimePeriod': 1000000,
        'CpuRealtimeRuntime': 950000,
        'NanoCpus': 500000000,
        'PidsLimit': 100,
        'ShmSize': 67108864,
        'MemorySwap': -1,
        'MemorySwappiness': 60,
        'MemoryReservation': 536870912,
        'KernelMemoryTCP': 0,
      });
      expect(hc.cpuPeriod, equals(100000));
      expect(hc.cpuQuota, equals(50000));
      expect(hc.cpuRealtimePeriod, equals(1000000));
      expect(hc.cpuRealtimeRuntime, equals(950000));
      expect(hc.nanoCpus, equals(500000000));
      expect(hc.pidsLimit, equals(100));
      expect(hc.shmSize, equals(67108864));
      expect(hc.memorySwap, equals(-1));
      expect(hc.memorySwappiness, equals(60));
      expect(hc.memoryReservation, equals(536870912));
      expect(hc.kernelMemoryTCP, equals(0));
    });

    test('parses consoleSize list', () {
      // ConsoleSize is [rows, columns] on Windows.
      final hc = ContainerHostConfig.fromJson({
        'ConsoleSize': [24, 80],
      });
      expect(hc.consoleSize, isNotNull);
      expect(hc.consoleSize, equals([24, 80]));
    });

    test('parses string scalar fields', () {
      final hc = ContainerHostConfig.fromJson({
        'CgroupParent': '/docker',
        'BlkioWeight': 0,
        'CgroupnsMode': 'private',
        'Runtime': 'runc',
        'Isolation': '',
        'IpcMode': 'private',
        'UTSMode': '',
        'UsernsMode': '',
        'PidMode': '',
        'CpusetCpus': '0-3',
        'CpusetMems': '0',
        'VolumeDriver': 'local',
        'ContainerIDFile': '/run/cid',
      });
      expect(hc.cgroupParent, equals('/docker'));
      expect(hc.blkioWeight, equals(0));
      expect(hc.cgroupnsMode, equals('private'));
      expect(hc.runtime, equals('runc'));
      expect(hc.ipcMode, equals('private'));
      expect(hc.cpusetCpus, equals('0-3'));
      expect(hc.cpusetMems, equals('0'));
      expect(hc.volumeDriver, equals('local'));
      expect(hc.containerIDFile, equals('/run/cid'));
    });

    test('tolerates empty input — all fields are null', () {
      final hc = ContainerHostConfig.fromJson({});
      expect(hc.memory, isNull);
      expect(hc.cpuShares, isNull);
      expect(hc.ulimits, isNull);
      expect(hc.devices, isNull);
      expect(hc.portBindings, isNull);
      expect(hc.logConfig, isNull);
      expect(hc.restartPolicy, isNull);
      expect(hc.capAdd, isNull);
      expect(hc.capDrop, isNull);
      expect(hc.sysctls, isNull);
      expect(hc.privileged, isNull);
      expect(hc.autoRemove, isNull);
      expect(hc.mounts, isNull);
      expect(hc.consoleSize, isNull);
    });
  });

  group('ContainerNetworkSettings null fields', () {
    test('handles null Networks and Ports', () {
      final ns = ContainerNetworkSettings.fromJson({
        'IPAddress': '172.17.0.2',
        'Networks': null,
        'Ports': null,
      });
      expect(ns.ipAddress, equals('172.17.0.2'));
      expect(ns.networks, isNull);
      expect(ns.ports, isNull);
    });
  });

  group('ContainerNetworkSettings.ports parsing', () {
    test('parses ports with non-null bindings', () {
      // Docker inspect response when a container has published ports.
      final ns = ContainerNetworkSettings.fromJson({
        'Ports': {
          '80/tcp': [
            {'HostIp': '0.0.0.0', 'HostPort': '32768'},
          ],
          '443/tcp': [
            {'HostIp': '0.0.0.0', 'HostPort': '32769'},
          ],
        },
      });
      expect(ns.ports, isNotNull);
      expect(ns.ports!.containsKey('80/tcp'), isTrue);
      expect(ns.ports!['80/tcp']!.first.hostPort, equals('32768'));
      expect(ns.ports!.containsKey('443/tcp'), isTrue);
      expect(ns.ports!['443/tcp']!.first.hostPort, equals('32769'));
    });

    test('parses port entry whose value is null (exposed but not published)',
        () {
      // Docker returns null for a port that is exposed but not published
      // (i.e. declared with EXPOSE but no -p flag at run time).
      final ns = ContainerNetworkSettings.fromJson({
        'Ports': {
          '80/tcp': null,
        },
      });
      expect(ns.ports, isNotNull);
      expect(ns.ports!.containsKey('80/tcp'), isTrue);
      // Null value = exposed but not bound to a host port.
      expect(ns.ports!['80/tcp'], isNull);
    });

    test('parses multiple bindings for one port (e.g. dual-stack)', () {
      // Docker can return multiple host bindings per container port
      // when both IPv4 (0.0.0.0) and IPv6 (::) are bound.
      final ns = ContainerNetworkSettings.fromJson({
        'Ports': {
          '80/tcp': [
            {'HostIp': '0.0.0.0', 'HostPort': '32768'},
            {'HostIp': '::', 'HostPort': '32768'},
          ],
        },
      });
      expect(ns.ports!['80/tcp']!.length, equals(2));
      expect(ns.ports!['80/tcp']![1].hostIp, equals('::'));
    });

    test('empty Ports map produces empty ports field', () {
      final ns = ContainerNetworkSettings.fromJson({'Ports': <String, dynamic>{}});
      expect(ns.ports, isNotNull);
      expect(ns.ports!, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // ContainerNetworkSettings — scalar and metadata fields
  // ---------------------------------------------------------------------------
  group('ContainerNetworkSettings scalar fields', () {
    test('parses bridge, sandboxID, hairpinMode, and link-local IPv6 fields', () {
      final ns = ContainerNetworkSettings.fromJson({
        'Bridge': 'docker0',
        'SandboxID': 'sandbox123',
        'HairpinMode': false,
        'LinkLocalIPv6Address': 'fe80::1',
        'LinkLocalIPv6PrefixLen': '64',
        'SandboxKey': '/var/run/docker/netns/abc',
      });
      expect(ns.bridge, equals('docker0'));
      expect(ns.sandboxID, equals('sandbox123'));
      expect(ns.hairpinMode, isFalse);
      expect(ns.linkLocalIPv6Address, equals('fe80::1'));
      expect(ns.linkLocalIPv6PrefixLen, equals('64'));
      expect(ns.sandboxKey, equals('/var/run/docker/netns/abc'));
    });

    test('parses endpointID, gateway, globalIPv6Address fields', () {
      final ns = ContainerNetworkSettings.fromJson({
        'EndpointID': 'ep456',
        'Gateway': '172.17.0.1',
        'GlobalIPv6Address': '2001:db8::1',
        'GlobalIPv6PrefixLen': 64,
        'IPAddress': '172.17.0.2',
        'IPPrefixLen': 16,
        'IPv6Gateway': 'fe80::1',
        'MacAddress': '02:42:ac:11:00:02',
      });
      expect(ns.endpointID, equals('ep456'));
      expect(ns.gateway, equals('172.17.0.1'));
      expect(ns.globalIPv6Address, equals('2001:db8::1'));
      expect(ns.globalIPv6PrefixLen, equals(64));
      expect(ns.ipAddress, equals('172.17.0.2'));
      expect(ns.ipPrefixLen, equals(16));
      expect(ns.ipv6Gateway, equals('fe80::1'));
      expect(ns.macAddress, equals('02:42:ac:11:00:02'));
    });

    test('parses secondaryIPv6Addresses list', () {
      final ns = ContainerNetworkSettings.fromJson({
        'SecondaryIPv6Addresses': [
          {'Addr': '2001:db8::2', 'PrefixLen': 64},
        ],
      });
      expect(ns.secondaryIPv6Addresses, isNotNull);
      expect(ns.secondaryIPv6Addresses!.length, equals(1));
      expect(ns.secondaryIPv6Addresses![0].addr, equals('2001:db8::2'));
      expect(ns.secondaryIPv6Addresses![0].prefixLen, equals(64));
    });

    test('tolerates all absent optional fields', () {
      final ns = ContainerNetworkSettings.fromJson({});
      expect(ns.bridge, isNull);
      expect(ns.sandboxID, isNull);
      expect(ns.hairpinMode, isNull);
      expect(ns.endpointID, isNull);
      expect(ns.gateway, isNull);
      expect(ns.macAddress, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // ContainerInspectInfo — untested scalar fields
  // ---------------------------------------------------------------------------
  group('ContainerInspectInfo scalar fields', () {
    test('parses created, path, args, restartCount, driver, platform', () {
      final info = ContainerInspectInfo.fromJson({
        'Id': 'abc123',
        'Created': '2024-06-01T12:00:00Z',
        'Path': '/bin/sh',
        'Args': ['-c', 'echo hello'],
        'RestartCount': 2,
        'Driver': 'overlay2',
        'Platform': 'linux',
      });
      expect(info.created, equals('2024-06-01T12:00:00Z'));
      expect(info.path, equals('/bin/sh'));
      expect(info.args, equals(['-c', 'echo hello']));
      expect(info.restartCount, equals(2));
      expect(info.driver, equals('overlay2'));
      expect(info.platform, equals('linux'));
    });

    test('parses host paths and security labels', () {
      final info = ContainerInspectInfo.fromJson({
        'ResolvConfPath': '/var/lib/docker/containers/abc/resolv.conf',
        'HostnamePath': '/var/lib/docker/containers/abc/hostname',
        'HostsPath': '/var/lib/docker/containers/abc/hosts',
        'LogPath': '/var/lib/docker/containers/abc/json.log',
        'MountLabel': '',
        'ProcessLabel': '',
        'AppArmorProfile': 'docker-default',
      });
      expect(
        info.resolvConfPath,
        equals('/var/lib/docker/containers/abc/resolv.conf'),
      );
      expect(
        info.hostnamePath,
        equals('/var/lib/docker/containers/abc/hostname'),
      );
      expect(
        info.hostsPath,
        equals('/var/lib/docker/containers/abc/hosts'),
      );
      expect(
        info.logPath,
        equals('/var/lib/docker/containers/abc/json.log'),
      );
      expect(info.mountLabel, isEmpty);
      expect(info.appArmorProfile, equals('docker-default'));
    });

    test('parses execIDs list', () {
      final info = ContainerInspectInfo.fromJson({
        'ExecIDs': ['exec1', 'exec2'],
      });
      expect(info.execIDs, equals(['exec1', 'exec2']));
    });

    test('execIDs is null when key absent', () {
      final info = ContainerInspectInfo.fromJson({});
      expect(info.execIDs, isNull);
    });

    test('parses nested graphDriver via fromJson', () {
      // graphDriver is delegated from ContainerInspectInfo.fromJson.
      final info = ContainerInspectInfo.fromJson({
        'GraphDriver': {
          'Name': 'overlay2',
          'Data': {'UpperDir': '/upper', 'WorkDir': '/work'},
        },
      });
      expect(info.graphDriver, isNotNull);
      expect(info.graphDriver!.name, equals('overlay2'));
      expect(info.graphDriver!.data!['UpperDir'], equals('/upper'));
    });

    test('graphDriver is null when GraphDriver key absent', () {
      final info = ContainerInspectInfo.fromJson({});
      expect(info.graphDriver, isNull);
    });

    test('parses nested imageManifestDescriptor via fromJson', () {
      final info = ContainerInspectInfo.fromJson({
        'ImageManifestDescriptor': {
          'mediaType': 'application/vnd.oci.image.manifest.v1+json',
          'digest': 'sha256:abc',
          'size': 512,
        },
      });
      expect(info.imageManifestDescriptor, isNotNull);
      expect(info.imageManifestDescriptor!.digest, equals('sha256:abc'));
    });

    test('imageManifestDescriptor is null when key absent', () {
      final info = ContainerInspectInfo.fromJson({});
      expect(info.imageManifestDescriptor, isNull);
    });

    test('parses sizeRw and sizeRootFs as string (via toString)', () {
      // Docker returns these as numbers; fromJson calls toString() on them.
      final info = ContainerInspectInfo.fromJson({
        'SizeRw': 4096,
        'SizeRootFs': 123456789,
      });
      expect(info.sizeRw, equals('4096'));
      expect(info.sizeRootFs, equals('123456789'));
    });

    test('parses processLabel', () {
      // processLabel is not asserted elsewhere — this test specifically
      // exercises the ProcessLabel JSON key.
      final info = ContainerInspectInfo.fromJson({
        'ProcessLabel': 'system_u:system_r:svirt_lxc_net_t:s0:c123,c456',
      });
      expect(
        info.processLabel,
        equals('system_u:system_r:svirt_lxc_net_t:s0:c123,c456'),
      );
    });

    test('processLabel defaults to null when key absent', () {
      final info = ContainerInspectInfo.fromJson({});
      expect(info.processLabel, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // ContainerNetworkEndpoint — gwPriority field (untested)
  // ---------------------------------------------------------------------------
  group('ContainerNetworkEndpoint gwPriority', () {
    test('parses gwPriority list', () {
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net1',
        'IPAddress': '10.0.0.2',
        'Gateway': '10.0.0.1',
        'GwPriority': [0, 1],
      });
      expect(endpoint.gwPriority, isNotNull);
      expect(endpoint.gwPriority, equals([0, 1]));
    });

    test('gwPriority is null when key absent', () {
      final endpoint = ContainerNetworkEndpoint.fromJson({
        'NetworkID': 'net1',
        'IPAddress': '10.0.0.2',
        'Gateway': '10.0.0.1',
      });
      expect(endpoint.gwPriority, isNull);
    });
  });

  group('ContainerState health', () {
    test('parses nested health object inside state', () {
      final state = ContainerState.fromJson({
        'Status': 'running',
        'Running': true,
        'Paused': false,
        'Restarting': false,
        'OOMKilled': false,
        'Dead': false,
        'Pid': 42,
        'ExitCode': 0,
        'Error': '',
        'StartedAt': '2024-01-01T00:00:01Z',
        'FinishedAt': '0001-01-01T00:00:00Z',
        'Health': {
          'Status': 'healthy',
          'FailingStreak': 0,
          'Log': [],
        },
      });
      expect(state.health, isNotNull);
      expect(state.health!.status, equals('healthy'));
    });

    test('health is null when absent from json', () {
      final state = ContainerState.fromJson({
        'Status': 'running',
        'Running': true,
        'Pid': 1,
        'ExitCode': 0,
      });
      expect(state.health, isNull);
    });
  });

  group('ContainerMount', () {
    test('parses mount fields', () {
      final mount = ContainerMount.fromJson({
        'Type': 'bind',
        'Source': '/host/data',
        'Destination': '/data',
        'Mode': 'rw',
        'RW': true,
        'Propagation': 'rprivate',
      });
      expect(mount.type, equals('bind'));
      expect(mount.source, equals('/host/data'));
      expect(mount.destination, equals('/data'));
      expect(mount.mode, equals('rw'));
      expect(mount.rw, isTrue);
    });

    test('tolerates missing optional fields', () {
      final mount = ContainerMount.fromJson({});
      expect(mount.type, isNull);
      expect(mount.source, isNull);
    });
  });

  group('ContainerInspectInfo.fromJson full round-trip', () {
    test('mounts list is parsed', () {
      final info = ContainerInspectInfo.fromJson({
        'Mounts': [
          {
            'Type': 'volume',
            'Source': '/var/lib/docker/volumes/data/_data',
            'Destination': '/data',
            'Mode': '',
            'RW': true,
            'Propagation': '',
          },
        ],
      });
      expect(info.mounts, isNotNull);
      expect(info.mounts!.length, equals(1));
      expect(info.mounts!.first.type, equals('volume'));
    });

    test('Config Env list is null-safe', () {
      final info = ContainerInspectInfo.fromJson({
        'Config': {'Image': 'alpine', 'Hostname': 'h', 'Env': null},
      });
      expect(info.config!.env, isNull);
    });
  });

  group('ContainerLog', () {
    test('fromJson parses all fields', () {
      final log = ContainerLog.fromJson({
        'Start': '2024-01-01T00:00:00Z',
        'End': '2024-01-01T00:00:01Z',
        'ExitCode': 0,
        'Output': 'health ok',
      });
      expect(log.start, equals('2024-01-01T00:00:00Z'));
      expect(log.end, equals('2024-01-01T00:00:01Z'));
      expect(log.exitCode, equals(0));
      expect(log.output, equals('health ok'));
    });

    test('fromJson tolerates missing fields', () {
      final log = ContainerLog.fromJson({});
      expect(log.start, isNull);
      expect(log.exitCode, isNull);
    });
  });

  group('ContainerPortBinding', () {
    test('fromJson parses hostIp and hostPort', () {
      final binding = ContainerPortBinding.fromJson({
        'HostIp': '0.0.0.0',
        'HostPort': '32768',
      });
      expect(binding.hostIp, equals('0.0.0.0'));
      expect(binding.hostPort, equals('32768'));
    });
  });

  group('ContainerRestartPolicy', () {
    test('fromJson parses name and maximumRetryCount', () {
      final policy = ContainerRestartPolicy.fromJson({
        'Name': 'on-failure',
        'MaximumRetryCount': 3,
      });
      expect(policy.name, equals('on-failure'));
      expect(policy.maximumRetryCount, equals(3));
    });
  });

  group('ContainerLogConfig', () {
    test('fromJson parses type and config', () {
      final logConfig = ContainerLogConfig.fromJson({
        'Type': 'json-file',
        'Config': {'max-size': '10m', 'max-file': '3'},
      });
      expect(logConfig.type, equals('json-file'));
      expect(logConfig.config, equals({'max-size': '10m', 'max-file': '3'}));
    });

    test('fromJson handles null config map', () {
      final logConfig = ContainerLogConfig.fromJson({'Type': 'none'});
      expect(logConfig.config, isNull);
    });
  });

  group('ContainerUlimit', () {
    test('fromJson parses name, soft, and hard', () {
      final ulimit = ContainerUlimit.fromJson({
        'Name': 'nofile',
        'Soft': 1024,
        'Hard': 4096,
      });
      expect(ulimit.name, equals('nofile'));
      expect(ulimit.soft, equals(1024));
      expect(ulimit.hard, equals(4096));
    });
  });

  group('ContainerVolumeDriverConfig', () {
    test('fromJson parses name and options', () {
      final driverConfig = ContainerVolumeDriverConfig.fromJson({
        'Name': 'local',
        'Options': {'type': 'tmpfs', 'device': 'tmpfs'},
      });
      expect(driverConfig.name, equals('local'));
      expect(driverConfig.options, equals({'type': 'tmpfs', 'device': 'tmpfs'}));
    });
  });

  group('ContainerPlatform', () {
    test('fromJson parses architecture, os, and variant', () {
      final platform = ContainerPlatform.fromJson({
        'architecture': 'amd64',
        'os': 'linux',
        'variant': '',
      });
      expect(platform.architecture, equals('amd64'));
      expect(platform.os, equals('linux'));
      expect(platform.variant, isEmpty);
    });

    test('fromJson tolerates missing fields', () {
      final platform = ContainerPlatform.fromJson({});
      expect(platform.architecture, isNull);
      expect(platform.os, isNull);
      expect(platform.variant, isNull);
    });
  });

  group('ContainerImageManifestDescriptor', () {
    test('fromJson parses scalar fields', () {
      final desc = ContainerImageManifestDescriptor.fromJson({
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'digest': 'sha256:abc123',
        'size': 1024,
        'artifactType': 'application/vnd.docker.container.image.v1+json',
      });
      expect(
        desc.mediaType,
        equals('application/vnd.oci.image.manifest.v1+json'),
      );
      expect(desc.digest, equals('sha256:abc123'));
      expect(desc.size, equals(1024));
      expect(desc.artifactType, isNotNull);
    });

    test('fromJson parses nested platform', () {
      final desc = ContainerImageManifestDescriptor.fromJson({
        'digest': 'sha256:abc',
        'platform': {'architecture': 'arm64', 'os': 'linux'},
      });
      expect(desc.platform, isNotNull);
      expect(desc.platform!.architecture, equals('arm64'));
    });

    test('fromJson handles null platform', () {
      final desc = ContainerImageManifestDescriptor.fromJson({});
      expect(desc.platform, isNull);
    });
  });

  group('ContainerBlkioWeightDevice', () {
    test('fromJson parses path and weight', () {
      final dev = ContainerBlkioWeightDevice.fromJson({
        'Path': '/dev/sda',
        'Weight': 500,
      });
      expect(dev.path, equals('/dev/sda'));
      expect(dev.weight, equals(500));
    });

    test('fromJson tolerates missing fields', () {
      final dev = ContainerBlkioWeightDevice.fromJson({});
      expect(dev.path, isNull);
      expect(dev.weight, isNull);
    });
  });

  group('ContainerBlkioDeviceRate', () {
    test('fromJson parses path and rate', () {
      final rate = ContainerBlkioDeviceRate.fromJson({
        'Path': '/dev/nvme0n1',
        'Rate': 104857600,
      });
      expect(rate.path, equals('/dev/nvme0n1'));
      expect(rate.rate, equals(104857600));
    });
  });

  group('ContainerDeviceMapping', () {
    test('fromJson parses pathOnHost, pathInContainer, cgroupPermissions', () {
      final mapping = ContainerDeviceMapping.fromJson({
        'PathOnHost': '/dev/ttyUSB0',
        'PathInContainer': '/dev/ttyUSB0',
        'CgroupPermissions': 'rwm',
      });
      expect(mapping.pathOnHost, equals('/dev/ttyUSB0'));
      expect(mapping.pathInContainer, equals('/dev/ttyUSB0'));
      expect(mapping.cgroupPermissions, equals('rwm'));
    });
  });

  group('ContainerDeviceRequest', () {
    test('fromJson parses driver, count, and deviceIDs', () {
      final req = ContainerDeviceRequest.fromJson({
        'Driver': 'nvidia',
        'Count': -1,
        'DeviceIDs': ['GPU-abc', 'GPU-def'],
        'Capabilities': [
          ['gpu'],
          ['nvidia', 'compute'],
        ],
        'Options': {'key': 'value'},
      });
      expect(req.driver, equals('nvidia'));
      expect(req.count, equals(-1));
      expect(req.deviceIDs, equals(['GPU-abc', 'GPU-def']));
      final expectedCaps = <List<String>>[
        ['gpu'],
        ['nvidia', 'compute'],
      ];
      expect(req.capabilities, equals(expectedCaps));
      expect(req.options, equals({'key': 'value'}));
    });

    test('fromJson tolerates missing fields', () {
      final req = ContainerDeviceRequest.fromJson({});
      expect(req.driver, isNull);
      expect(req.capabilities, isNull);
    });
  });

  group('ContainerBindOptions', () {
    test('fromJson parses all fields', () {
      final opts = ContainerBindOptions.fromJson({
        'Propagation': 'rprivate',
        'NonRecursive': false,
        'CreateMountpoint': true,
        'ReadOnlyNonRecursive': false,
        'ReadOnlyForceRecursive': false,
      });
      expect(opts.propagation, equals('rprivate'));
      expect(opts.nonRecursive, isFalse);
      expect(opts.createMountpoint, isTrue);
    });

    test('fromJson tolerates missing fields', () {
      final opts = ContainerBindOptions.fromJson({});
      expect(opts.propagation, isNull);
      expect(opts.createMountpoint, isNull);
    });
  });

  group('ContainerVolumeOptions', () {
    test('fromJson parses noCopy, labels, and nested driverConfig', () {
      final opts = ContainerVolumeOptions.fromJson({
        'NoCopy': false,
        'Labels': {'com.example.owner': 'test'},
        'DriverConfig': {'Name': 'local', 'Options': {'device': 'tmpfs'}},
        'Subpath': 'data',
      });
      expect(opts.noCopy, isFalse);
      expect(opts.labels, equals({'com.example.owner': 'test'}));
      expect(opts.driverConfig, isNotNull);
      expect(opts.driverConfig!.name, equals('local'));
      expect(opts.subpath, equals('data'));
    });

    test('fromJson handles null DriverConfig', () {
      final opts = ContainerVolumeOptions.fromJson({});
      expect(opts.driverConfig, isNull);
    });
  });

  group('ContainerImageOptions', () {
    test('fromJson parses subpath', () {
      final opts = ContainerImageOptions.fromJson({'Subpath': '/app'});
      expect(opts.subpath, equals('/app'));
    });

    test('fromJson tolerates missing subpath', () {
      final opts = ContainerImageOptions.fromJson({});
      expect(opts.subpath, isNull);
    });
  });

  group('ContainerTmpfsOptions', () {
    test('fromJson parses sizeBytes and mode', () {
      final opts = ContainerTmpfsOptions.fromJson({
        'SizeBytes': 67108864,
        'Mode': 493,
        'Options': [
          ['size', '64m'],
          ['uid', '1000'],
        ],
      });
      expect(opts.sizeBytes, equals(67108864));
      expect(opts.mode, equals(493));
      final expectedOptions = <List<String>>[
        ['size', '64m'],
        ['uid', '1000'],
      ];
      expect(opts.options, equals(expectedOptions));
    });

    test('fromJson tolerates missing fields', () {
      final opts = ContainerTmpfsOptions.fromJson({});
      expect(opts.sizeBytes, isNull);
      expect(opts.options, isNull);
    });
  });

  group('ContainerMountPoint', () {
    test('fromJson parses type, source, target, and readOnly', () {
      final mp = ContainerMountPoint.fromJson({
        'Type': 'bind',
        'Source': '/host/path',
        'Target': '/container/path',
        'ReadOnly': true,
        'Consistency': 'default',
      });
      expect(mp.type, equals('bind'));
      expect(mp.source, equals('/host/path'));
      expect(mp.target, equals('/container/path'));
      expect(mp.readOnly, isTrue);
      expect(mp.consistency, equals('default'));
    });

    test('fromJson parses nested BindOptions', () {
      final mp = ContainerMountPoint.fromJson({
        'Type': 'bind',
        'BindOptions': {'Propagation': 'shared'},
      });
      expect(mp.bindOptions, isNotNull);
      expect(mp.bindOptions!.propagation, equals('shared'));
    });

    test('fromJson parses nested VolumeOptions', () {
      final mp = ContainerMountPoint.fromJson({
        'Type': 'volume',
        'VolumeOptions': {'NoCopy': true},
      });
      expect(mp.volumeOptions, isNotNull);
      expect(mp.volumeOptions!.noCopy, isTrue);
    });

    test('fromJson parses nested TmpfsOptions', () {
      final mp = ContainerMountPoint.fromJson({
        'Type': 'tmpfs',
        'TmpfsOptions': {'SizeBytes': 1048576},
      });
      expect(mp.tmpfsOptions, isNotNull);
      expect(mp.tmpfsOptions!.sizeBytes, equals(1048576));
    });

    test('fromJson parses nested ImageOptions', () {
      final mp = ContainerMountPoint.fromJson({
        'Type': 'image',
        'ImageOptions': {'Subpath': '/data'},
      });
      expect(mp.imageOptions, isNotNull);
      expect(mp.imageOptions!.subpath, equals('/data'));
    });

    test('fromJson tolerates missing options', () {
      final mp = ContainerMountPoint.fromJson({});
      expect(mp.bindOptions, isNull);
      expect(mp.volumeOptions, isNull);
      expect(mp.imageOptions, isNull);
      expect(mp.tmpfsOptions, isNull);
    });
  });

  group('ContainerGraphDriver', () {
    test('fromJson parses name and data', () {
      final driver = ContainerGraphDriver.fromJson({
        'Name': 'overlay2',
        'Data': {
          'LowerDir': '/var/lib/docker/overlay2/abc/diff',
          'MergedDir': '/var/lib/docker/overlay2/abc/merged',
        },
      });
      expect(driver.name, equals('overlay2'));
      expect(driver.data, isNotNull);
      expect(driver.data!['LowerDir'], isNotNull);
    });

    test('fromJson tolerates null data', () {
      final driver = ContainerGraphDriver.fromJson({'Name': 'overlay2'});
      expect(driver.data, isNull);
    });
  });

  group('ContainerIPAMConfig', () {
    test('fromJson parses ipv4Address, ipv6Address, and linkLocalIPs', () {
      final config = ContainerIPAMConfig.fromJson({
        'IPv4Address': '10.0.0.5',
        'IPv6Address': '',
        'LinkLocalIPs': ['169.254.0.1'],
      });
      expect(config.ipv4Address, equals('10.0.0.5'));
      expect(config.ipv6Address, isEmpty);
      expect(config.linkLocalIPs, equals(['169.254.0.1']));
    });

    test('fromJson tolerates missing fields', () {
      final config = ContainerIPAMConfig.fromJson({});
      expect(config.ipv4Address, isNull);
      expect(config.linkLocalIPs, isNull);
    });
  });

  group('ContainerAddress', () {
    test('fromJson parses addr and prefixLen', () {
      final addr = ContainerAddress.fromJson({'Addr': '10.0.0.2', 'PrefixLen': 24});
      expect(addr.addr, equals('10.0.0.2'));
      expect(addr.prefixLen, equals(24));
    });

    test('fromJson tolerates missing fields', () {
      final addr = ContainerAddress.fromJson({});
      expect(addr.addr, isNull);
      expect(addr.prefixLen, isNull);
    });
  });

  group('ContainerState full field parsing', () {
    test('fromJson parses all boolean and string state fields', () {
      final state = ContainerState.fromJson({
        'Status': 'exited',
        'Running': false,
        'Paused': false,
        'Restarting': false,
        'OOMKilled': true,
        'Dead': false,
        'Pid': 0,
        'ExitCode': 137,
        'Error': 'container killed',
        'StartedAt': '2024-05-01T10:00:00Z',
        'FinishedAt': '2024-05-01T10:00:05Z',
      });
      expect(state.status, equals('exited'));
      expect(state.running, isFalse);
      expect(state.paused, isFalse);
      expect(state.restarting, isFalse);
      expect(state.oomKilled, isTrue);
      expect(state.dead, isFalse);
      expect(state.pid, equals(0));
      expect(state.exitCode, equals(137));
      expect(state.error, equals('container killed'));
      expect(state.startedAt, equals('2024-05-01T10:00:00Z'));
      expect(state.finishedAt, equals('2024-05-01T10:00:05Z'));
    });

    test('fromJson tolerates all missing fields', () {
      final state = ContainerState.fromJson({});
      expect(state.status, isNull);
      expect(state.running, isNull);
      expect(state.paused, isNull);
      expect(state.restarting, isNull);
      expect(state.oomKilled, isNull);
      expect(state.dead, isNull);
      expect(state.pid, isNull);
      expect(state.exitCode, isNull);
      expect(state.error, isNull);
      expect(state.startedAt, isNull);
      expect(state.finishedAt, isNull);
      expect(state.health, isNull);
    });

    test('dead=true indicates a container in the "dead" state', () {
      final state = ContainerState.fromJson({
        'Status': 'dead',
        'Dead': true,
        'Running': false,
        'ExitCode': 1,
      });
      expect(state.dead, isTrue);
      expect(state.status, equals('dead'));
    });

    test('restarting=true is preserved', () {
      final state = ContainerState.fromJson({
        'Status': 'restarting',
        'Restarting': true,
        'Running': false,
      });
      expect(state.restarting, isTrue);
    });

    test('paused=true is preserved', () {
      final state = ContainerState.fromJson({
        'Status': 'paused',
        'Paused': true,
        'Running': false,
      });
      expect(state.paused, isTrue);
    });
  });

  group('ContainerNetworkSettings secondary addresses', () {
    test('fromJson parses secondaryIPAddresses', () {
      final settings = ContainerNetworkSettings.fromJson({
        'SecondaryIPAddresses': [
          {'Addr': '172.18.0.5', 'PrefixLen': 16},
        ],
      });
      expect(settings.secondaryIPAddresses, isNotNull);
      expect(settings.secondaryIPAddresses!.length, equals(1));
      expect(settings.secondaryIPAddresses![0].addr, equals('172.18.0.5'));
    });

    test('fromJson parses networks map', () {
      final settings = ContainerNetworkSettings.fromJson({
        'Networks': {
          'bridge': {
            'IPAddress': '172.17.0.2',
            'Gateway': '172.17.0.1',
            'NetworkID': 'net123',
          },
        },
      });
      expect(settings.networks, isNotNull);
      expect(settings.networks!['bridge'], isNotNull);
      expect(settings.networks!['bridge']!.ipAddress, equals('172.17.0.2'));
    });

    test('fromJson with null Networks returns null networks field', () {
      final settings = ContainerNetworkSettings.fromJson({});
      expect(settings.networks, isNull);
    });
  });
}
