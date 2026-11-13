class FamilyAccessState {
  FamilyAccessState({
    required this.familyId,
    required this.version,
    required this.active,
    required this.lastRevokedVersion,
    required Set<String> childIds,
  }) : childIds = Set.unmodifiable(childIds) {
    if (version < 1 ||
        lastRevokedVersion < 0 ||
        lastRevokedVersion > version ||
        (!active && lastRevokedVersion == 0)) {
      throw FormatException('Invalid membership state');
    }
  }
  factory FamilyAccessState.fromJson(Map<String, dynamic> value) =>
      FamilyAccessState(
        familyId: value['family_id'] as String,
        version: (value['version'] as num).toInt(),
        active: value['active'] as bool,
        lastRevokedVersion: (value['last_revoked_version'] as num).toInt(),
        childIds: (value['child_ids'] as List).cast<String>().toSet(),
      );
  final String familyId;
  final int version, lastRevokedVersion;
  final bool active;
  final Set<String> childIds;
}

class FamilyAccessChange {
  FamilyAccessChange(
    this.owner,
    this.familyId,
    this.version,
    Set<String> children,
  ) : childIds = Set.unmodifiable(children);
  final String owner, familyId;
  final int version;
  final Set<String> childIds;
}
