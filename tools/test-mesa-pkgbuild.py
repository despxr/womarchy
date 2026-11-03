#!/usr/bin/env python3
"""Regression tests for the Mesa rebuild, without installing packages."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "linux/packages"


class MesaPkgbuildTests(unittest.TestCase):
    def generate(self, source, output):
        return subprocess.run(
            [sys.executable, str(PACKAGES / "mesa-womarchy/make-pkgbuild.py"),
             "--rel", "2", str(source), str(output),
             *map(str, sorted((PACKAGES / "mesa-womarchy").glob("0*.patch")))],
            capture_output=True, text=True, check=False,
        )

    def test_committed_pkgbuild_is_reproducible(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "PKGBUILD"
            result = self.generate(PACKAGES / "ref/mesa.PKGBUILD", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            text = output.read_text()
            self.assertEqual(text, (PACKAGES / "mesa-womarchy/PKGBUILD").read_text())
            self.assertIn("pkgrel=2.2\n", text)
            self.assertEqual(text.count("    libLLVM.so\n"), 2)
            # The build dependency remains a normal package dependency.
            self.assertIn("  llvm\n  llvm-libs\n", text)
            result = subprocess.run(["bash", "-n", str(output)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_upstream_dependency_layout_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "reference"
            output = Path(tmp) / "PKGBUILD"
            text = (PACKAGES / "ref/mesa.PKGBUILD").read_text()
            source.write_text(text.replace("    llvm-libs\n", "    llvm-new-libs\n", 1))
            result = self.generate(source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected Mesa and lavapipe LLVM dependencies", result.stderr)
            self.assertFalse(output.exists())

    def test_new_scripts_parse(self):
        for name in ("publish-packages.sh", "check-mesa-llvm.sh"):
            with self.subTest(script=name):
                result = subprocess.run(["bash", "-n", str(ROOT / "tools" / name)],
                                        capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
