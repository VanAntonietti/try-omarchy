"""Pinned Blip preparation is a public, offline build boundary."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class PreparationTests(unittest.TestCase):
    def test_rejects_modified_archive_before_publishing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            shutil.copytree(ROOT, bundle, ignore=shutil.ignore_patterns("node_modules", "__pycache__"))
            with (bundle / "upstream/blip.tar.gz").open("ab") as archive:
                archive.write(b"corruption")
            output = root / "output"
            result = subprocess.run(
                ["python3", str(bundle / "prepare.py"), "--output", str(output)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("source checksum mismatch", result.stderr)
            self.assertFalse(output.exists())


    def test_rejects_modified_patch_before_publishing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            shutil.copytree(ROOT, bundle, ignore=shutil.ignore_patterns("node_modules", "__pycache__"))
            with (bundle / "transport.patch").open("ab") as patch:
                patch.write(b"corruption")
            output = root / "output"
            result = subprocess.run(
                ["python3", str(bundle / "prepare.py"), "--output", str(output)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("patch checksum mismatch", result.stderr)
            self.assertFalse(output.exists())

    def test_existing_source_tree_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            output.mkdir()
            marker = output / "keep"
            marker.write_text("existing source")
            result = subprocess.run(
                ["python3", str(ROOT / "prepare.py"), "--output", str(output)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "existing source")

    def test_prepares_patched_source_and_retains_license(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            result = subprocess.run(
                ["python3", str(ROOT / "prepare.py"), "--output", str(output)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("omarchy-link)", (output / "bridge/linux/blip-shim").read_text())
            self.assertEqual((output / "LICENSE").read_bytes(), (ROOT / "upstream/LICENSE").read_bytes())
            self.assertEqual((output / "bridge/linux/blip-link.ts").read_bytes(), (ROOT / "blip-link.ts").read_bytes())
            self.assertTrue((output / "TRY-OMARCHY-PROVENANCE.json").is_file())


if __name__ == "__main__":
    unittest.main()
