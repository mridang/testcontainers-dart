/// Semantic version comparison utility used internally by testcontainers-dart.
///
/// [ComparableVersion] parses a `major.minor.patch` version string and
/// exposes all six comparison operators so that minimum Docker API version
/// requirements can be checked at runtime.
library;

/// A parsed semantic version that supports full ordering.
///
/// Only the strict three-part `major.minor.patch` format is accepted. All
/// integer parts must be non-negative. Pre-release and build-metadata
/// suffixes (e.g. `-rc1`, `+build.1`) are **not** supported and will cause
/// a [FormatException].
///
/// Version objects are immutable. Comparison is lexicographic on the
/// `(major, minor, patch)` tuple.
///
/// Example:
/// ```dart
/// final v = ComparableVersion('1.41.0');
/// assert(v > ComparableVersion('1.40.0'));
/// assert(v == '1.41.0');
/// ```
class ComparableVersion implements Comparable<ComparableVersion> {
  /// The major version component.
  final int major;

  /// The minor version component.
  final int minor;

  /// The patch version component.
  final int patch;

  // The original string, preserved so toString() round-trips correctly.
  final String _original;

  // Pre-computed tuple for compareTo — unmodifiable so callers cannot
  // mutate the internal state through the List reference.
  late final List<int> _parts = List.unmodifiable([major, minor, patch]);

  /// Private constructor used by the factory after parsing.
  ComparableVersion._(this._original, this.major, this.minor, this.patch);

  /// Creates a [ComparableVersion] by parsing [version].
  ///
  /// The [version] string must be in `major.minor.patch` format where all
  /// three components are non-negative integers.
  ///
  /// Throws [FormatException] if [version] does not have exactly three
  /// dot-separated integer parts.
  factory ComparableVersion(String version) {
    final parts = version.split('.');
    if (parts.length != 3) {
      throw FormatException('Invalid version string: $version');
    }
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null) {
        throw FormatException('Invalid version string: $version');
      }
      nums.add(n);
    }
    return ComparableVersion._(version, nums[0], nums[1], nums[2]);
  }

  /// Compares this version to [other].
  ///
  /// Returns a negative integer if this version is lower than [other], zero
  /// if they are equal, and a positive integer if this version is greater.
  @override
  int compareTo(ComparableVersion other) {
    for (var i = 0; i < 3; i++) {
      final diff = _parts[i] - other._parts[i];
      if (diff != 0) {
        return diff;
      }
    }
    return 0;
  }

  /// Returns `true` if this version is strictly less than [other].
  ///
  /// [other] may be a [ComparableVersion] or a [String] that will be parsed
  /// on the fly. Throws [FormatException] if [other] is a [String] that
  /// cannot be parsed as a three-part version.
  bool operator <(Object other) {
    if (other is ComparableVersion) {
      return compareTo(other) < 0;
    }
    return compareTo(ComparableVersion(other.toString())) < 0;
  }

  /// Returns `true` if this version is less than or equal to [other].
  ///
  /// [other] may be a [ComparableVersion] or a parseable version [String].
  bool operator <=(Object other) {
    if (other is ComparableVersion) {
      return compareTo(other) <= 0;
    }
    return compareTo(ComparableVersion(other.toString())) <= 0;
  }

  /// Returns `true` if this version is strictly greater than [other].
  ///
  /// [other] may be a [ComparableVersion] or a parseable version [String].
  bool operator >(Object other) {
    if (other is ComparableVersion) {
      return compareTo(other) > 0;
    }
    return compareTo(ComparableVersion(other.toString())) > 0;
  }

  /// Returns `true` if this version is greater than or equal to [other].
  ///
  /// [other] may be a [ComparableVersion] or a parseable version [String].
  bool operator >=(Object other) {
    if (other is ComparableVersion) {
      return compareTo(other) >= 0;
    }
    return compareTo(ComparableVersion(other.toString())) >= 0;
  }

  /// Returns `true` if this version is equal to [other].
  ///
  /// [other] may be a [ComparableVersion] or a [String] representing the same
  /// version number. Returns `false` for any other type, and also returns
  /// `false` (rather than throwing) when [other] is a [String] that cannot be
  /// parsed as a valid `major.minor.patch` version — this keeps [operator ==]
  /// stable and consistent with Dart's equality contract.
  @override
  bool operator ==(Object other) {
    if (other is ComparableVersion) {
      return compareTo(other) == 0;
    }
    if (other is String) {
      try {
        return compareTo(ComparableVersion(other)) == 0;
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  /// Returns a hash code consistent with [operator ==].
  ///
  /// Two [ComparableVersion] instances that compare as equal always return the
  /// same hash code. The hash is derived from [major], [minor], and [patch].
  @override
  int get hashCode => Object.hash(major, minor, patch);

  /// Returns the canonical version string, e.g. `'1.2.3'`.
  ///
  /// Round-trips correctly: `ComparableVersion('1.2.3').toString() == '1.2.3'`.
  @override
  String toString() => _original;
}
