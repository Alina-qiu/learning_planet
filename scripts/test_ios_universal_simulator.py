"""A different or unavailable simulator must never satisfy the required target."""
import unittest

from prepare_ios_universal_simulator import compatible_runtime


def runtime(version="27.2", architectures=("arm64", "x86_64"), available=True):
    return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
            "supportedArchitectures": list(architectures), "isAvailable": available}


class UniversalRuntimeTests(unittest.TestCase):
    def test_accepts_available_requested_universal_runtime(self):
        selected = runtime()
        self.assertIs(compatible_runtime({"runtimes": [selected]}, "27.2"), selected)

    def test_arm_only_installation_does_not_pass(self):
        self.assertIsNone(compatible_runtime({"runtimes": [runtime(architectures=("arm64",))]}, "27.2"))

    def test_other_ios_release_does_not_substitute(self):
        self.assertIsNone(compatible_runtime({"runtimes": [runtime("26.2")]}, "27.2"))

    def test_unavailable_universal_runtime_does_not_pass(self):
        self.assertIsNone(compatible_runtime({"runtimes": [runtime(available=False)]}, "27.2"))

    def test_selects_compatible_variant_when_arm_variant_also_exists(self):
        selected = runtime()
        inventory = {"runtimes": [runtime(architectures=("arm64",)), selected]}
        self.assertIs(compatible_runtime(inventory, "27.2"), selected)


if __name__ == "__main__":
    unittest.main()
