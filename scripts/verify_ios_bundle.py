"""Check resources in a built iOS app; does not verify signing or runtime behavior."""

import argparse
import json
import plistlib
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError


def load_plist(path):
    with path.open("rb") as source:
        value = plistlib.load(source)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a property-list dictionary: {path}")
    return value


def verify(bundle, expected_sdk=None):
    source = Path(__file__).resolve().parents[1] / "ios" / "Runner"
    expected = load_plist(source / "PrivacyInfo.xcprivacy")
    actual = load_plist(bundle / "PrivacyInfo.xcprivacy")
    if actual != expected:
        raise ValueError("Bundled privacy manifest differs from the app source")
    info = load_plist(bundle / "Info.plist")
    if info.get("CFBundleIdentifier") != "com.learningplanet.learningPlanet":
        raise ValueError("Unexpected iOS bundle identifier")
    if expected_sdk is not None and info.get("DTSDKName") != expected_sdk:
        raise ValueError(f"Expected SDK {expected_sdk}, got {info.get('DTSDKName')!r}")
    minimum = tuple(int(part) for part in info["MinimumOSVersion"].split("."))
    if minimum < (15, 5):
        raise ValueError("iOS deployment target is below the ML Kit 15.5 minimum")
    source_info = load_plist(source / "Info.plist")
    for key in ("NSCameraUsageDescription", "NSPhotoLibraryUsageDescription"):
        if not info.get(key) or info[key] != source_info[key]:
            raise ValueError(f"Missing or changed camera/photo permission text: {key}")
    if "remote-notification" not in info.get("UIBackgroundModes", []):
        raise ValueError("Missing background notification mode")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise ValueError("Invalid app executable name")
    for relative in (
        executable,
        "Frameworks/App.framework/App",
        "Frameworks/Flutter.framework/Flutter",
        "Frameworks/App.framework/flutter_assets/AssetManifest.bin",
    ):
        file = bundle / relative
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f"Missing or empty Flutter app resource: {relative}")
    manifests = sorted(bundle.rglob("PrivacyInfo.xcprivacy"))
    for manifest in manifests:
        load_plist(manifest)
    return {
        "resource_check_passed": True,
        "bundle_id": info["CFBundleIdentifier"],
        "minimum_ios": info["MinimumOSVersion"],
        "build_sdk": info.get("DTSDKName"),
        "xcode_version": info.get("DTXcode"),
        "xcode_build": info.get("DTXcodeBuild"),
        "privacy_manifests_parsed": len(manifests),
        "app_api_categories": len(actual["NSPrivacyAccessedAPITypes"]),
        "app_data_categories": len(actual["NSPrivacyCollectedDataTypes"]),
        "scope": "bundle resources only; signing, launch and device behavior are not checked",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="Path to the freshly built Runner.app")
    parser.add_argument("--expected-sdk", help="Require this device SDK, for example iphoneos27.2")
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.bundle.resolve(), args.expected_sdk), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, ExpatError, plistlib.InvalidFileException) as error:
        print(f"iOS bundle resource check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
