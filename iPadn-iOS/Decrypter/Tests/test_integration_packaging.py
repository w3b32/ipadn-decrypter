"""Run the actual runner/lite packaging tools without Xcode or Apple accounts."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("make_lite", ROOT / "scripts/make_lite_ipa.py")
lite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lite)


class IntegrationPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.app = self.folder / "DecrypterRunner.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "DecrypterRunner", "MinimumOSVersion": "17.4", "TetherDecryptTemplate": True
        }))
        # Byte fixture tests ZIP layout/ownership. Physical Mach-O validation is
        # performed by verify_ipa.py against the actual Xcode-built product.
        (self.app / "DecrypterRunner").write_bytes(b"runner fixture")
        (self.app / "DecrypterRunner").chmod(0o755)
        self.template = self.folder / "HelperTemplate.ipa"

    def package(self):
        return subprocess.run([sys.executable, str(ROOT / "scripts/package_decrypter_runner.py"),
                               str(self.app), str(self.template)], capture_output=True, text=True)

    def test_standard_and_lite_keep_the_same_zipped_runner(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        template = self.template.read_bytes()
        with zipfile.ZipFile(self.template) as runner:
            self.assertEqual(runner.read("Payload/DecrypterRunner.app/DecrypterRunner"), b"runner fixture")
            info = plistlib.loads(runner.read("Payload/DecrypterRunner.app/Info.plist"))
            self.assertTrue(info["TetherDecryptTemplate"])
            self.assertIn("TetherDecryptCommit", info)
        standard, reduced = self.folder / "standard.ipa", self.folder / "lite.ipa"
        with zipfile.ZipFile(standard, "w") as main:
            main.writestr("Payload/iPadn.app/HelperTemplate.ipa", template)
            main.writestr("Payload/iPadn.app/iPadn", b"main fixture")
            main.writestr("Payload/iPadn.app/PlugIns/iPadnLiveActivity.appex/Info.plist", b"widget fixture")
        self.assertGreater(lite.make_lite(str(standard), str(reduced)), 0)
        with zipfile.ZipFile(reduced) as main:
            self.assertEqual(main.read("Payload/iPadn.app/HelperTemplate.ipa"), template)
            self.assertFalse(any("PlugIns/" in name for name in main.namelist()))
            self.assertFalse(any("DecrypterRunner.app" in name for name in main.namelist()))

    def test_signed_runner_is_rejected_and_previous_template_survives(self):
        self.assertEqual(self.package().returncode, 0)
        previous = self.template.read_bytes()
        signature = self.app / "_CodeSignature"
        signature.mkdir()
        (signature / "CodeResources").write_bytes(b"unexpected signature")
        self.assertNotEqual(self.package().returncode, 0)
        self.assertEqual(self.template.read_bytes(), previous)

    def test_symlink_in_runner_is_rejected(self):
        (self.app / "escaped").symlink_to(self.folder / "outside")
        self.assertNotEqual(self.package().returncode, 0)
        self.assertFalse(self.template.exists())


if __name__ == "__main__":
    unittest.main()
