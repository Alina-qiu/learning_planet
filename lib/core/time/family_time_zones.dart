import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

List<String>? _bundledNames;

/// Loads the bundled rules in this isolate. A caller may also install custom
/// locations or choose a local timezone independently of the family timezone.
void ensureFamilyTimeZones() {
  final locations = tz.timeZoneDatabase.locations;
  final names = _bundledNames;
  if (names != null &&
      locations.length >= names.length &&
      names.every(locations.containsKey)) {
    return;
  }
  final previous = Map.of(locations);
  tz.Location? selected;
  try {
    selected = tz.local;
  } on Error {
    // The package's late local field is unset in a fresh isolate, even if a
    // caller has already added a location to the database.
  }
  try {
    tzdata.initializeTimeZones();
  } catch (_) {
    locations
      ..clear()
      ..addAll(previous);
    rethrow;
  }
  _bundledNames = locations.keys.toList(growable: false);
  for (final entry in previous.entries) {
    locations.putIfAbsent(entry.key, () => entry.value);
  }
  if (selected != null) tz.setLocalLocation(selected);
}
