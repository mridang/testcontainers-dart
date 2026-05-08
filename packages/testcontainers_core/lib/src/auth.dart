/// Docker registry authentication helpers.
///
/// Parses the `DOCKER_AUTH_CONFIG` environment variable (or the equivalent
/// value in `~/.testcontainers.properties`) and converts the encoded
/// credentials into a list of [DockerAuthInfo] records that [DockerClient]
/// can pass to `POST /auth`.
library;

import 'dart:convert';
import 'dart:io';

/// Holds the credentials required to authenticate against a single Docker
/// registry.
///
/// All three fields are required:
/// - `registry` — the registry hostname, e.g. `'https://index.docker.io/v1/'`
/// - `username` — the account name
/// - `password` — the account password or personal-access token
typedef DockerAuthInfo = ({
  String registry,
  String username,
  String password,
});

// One-shot warning flags — printed to stderr the first time a
// credHelpers / credsStore key is encountered, then cleared.
String? _credHelpersWarning =
    'DOCKER_AUTH_CONFIG is experimental, credHelpers not supported yet';
String? _credsStoreWarning =
    'DOCKER_AUTH_CONFIG is experimental, credsStore not supported yet';

/// Parses a JSON Docker `config.json`-style auth configuration string.
///
/// The expected format mirrors what `docker login` writes into
/// `~/.docker/config.json`:
/// ```json
/// {
///   "auths": {
///     "https://index.docker.io/v1/": {
///       "auth": "<base64(username:password)>"
///     }
///   }
/// }
/// ```
///
/// Behaviour:
/// - Returns a [List<DockerAuthInfo>] with one entry per registry found under
///   the `auths` key. The list is unmodifiable.
/// - Returns `null` when the `auths` key is absent.
/// - Returns an empty list when `auths` is present but contains no entries.
/// - Emits a one-time warning to [stderr] when `credHelpers` or `credsStore`
///   keys are present, because those external credential helpers are not yet
///   supported.
///
/// Parameters:
/// - [authConfig] — the raw JSON string from `DOCKER_AUTH_CONFIG`.
///
/// Throws [ArgumentError] if [authConfig] is not valid JSON or the `auth`
/// value cannot be base64-decoded.
List<DockerAuthInfo>? parseDockerAuthConfig(String authConfig) {
  try {
    final Map<String, dynamic> config =
        jsonDecode(authConfig) as Map<String, dynamic>;

    if (config.containsKey('credHelpers') && _credHelpersWarning != null) {
      stderr.writeln(_credHelpersWarning);
      _credHelpersWarning = null;
    }
    if (config.containsKey('credsStore') && _credsStoreWarning != null) {
      stderr.writeln(_credsStoreWarning);
      _credsStoreWarning = null;
    }

    final auths = config['auths'] as Map<String, dynamic>?;
    if (auths == null) {
      return null;
    }

    final result = <DockerAuthInfo>[];
    for (final entry in auths.entries) {
      final authEntry = entry.value as Map<String, dynamic>;
      final authStr = utf8.decode(base64.decode(authEntry['auth'] as String));
      final colonIdx = authStr.indexOf(':');
      if (colonIdx < 0) {
        stderr.writeln(
          'testcontainers: skipping auth entry for registry '
          '"${entry.key}" — decoded credentials contain no colon separator.',
        );
        continue;
      }
      result.add(
        (
          registry: entry.key,
          username: authStr.substring(0, colonIdx),
          password: authStr.substring(colonIdx + 1),
        ),
      );
    }
    return List.unmodifiable(result);
  } on FormatException catch (e) {
    throw ArgumentError('Could not parse docker auth config: $e');
  } on TypeError catch (e) {
    throw ArgumentError('Unexpected structure in docker auth config: $e');
  }
}
