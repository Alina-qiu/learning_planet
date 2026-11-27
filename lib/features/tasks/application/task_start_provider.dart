import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth_family/application/family_providers.dart';
import '../domain/task_start_origin.dart';

final taskStartOriginProvider = Provider.family<TaskStartOrigin, String?>(
  (ref, family) => TaskStartOrigin.forMode(
    familyId: family,
    parentMode: ref.watch(parentModeProvider),
    parentFamilyId: ref.watch(parentFamilyIdProvider),
  ),
);
