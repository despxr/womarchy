#!/usr/bin/env python3
"""Test the actual repo-rewrite block in isolation; never change system files."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "linux/overlay/wsl/pacman.sh").read_text()
REWRITE = SOURCE.split("# --- [womarchy] block,", 1)[1].split(
    "# A [womarchy] database", 1
)[0]
REWRITE = REWRITE[REWRITE.index("tmp=$(mktemp"):]
HEADER = "[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n\n"
CORE = "[core]\nServer = https://arch.example/$arch\n\n"
OMARCHY = "[omarchy]\nServer = https://omarchy.example/$arch\n\n"
OLD = ("# womarchy repo (managed by womarchy-compat): must stay before [core] so its packages win\n"
       "[womarchy]\nSigLevel = Optional TrustAll\nServer = https://old.example\n\n")
HOSTED = "https://github.com/kineticz/womarchy/releases/download/packages"


class PacmanRepoTests(unittest.TestCase):
    def rewrite(self, content):
        with tempfile.TemporaryDirectory() as tmp:
            conf = Path(tmp) / "pacman.conf"
            conf.write_text(content)
            result = subprocess.run(
                ["bash", "-c", 'set -euo pipefail\nCONF=$1\nHOSTED=$2\n'
                 'REPO_DIR=/var/lib/womarchy/repo\nsiglevel="PackageOptional DatabaseRequired"\n'
                 'fail() { echo "$*" >&2; exit 1; }\n' + REWRITE,
                 "test", str(conf), HOSTED],
                capture_output=True, text=True,
            )
            output = conf.read_text()
            self.assertEqual(list(Path(tmp).iterdir()), [conf], "temporary files leaked")
            return result, output

    def check_rewrite(self, content, repos):
        result, output = self.rewrite(content)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(re.findall(r"^\[([^]]+)\]$", output, re.M), ["options", *repos])
        self.assertIn("Server = " + HOSTED, output)
        self.assertIn("Server = file:///var/lib/womarchy/repo", output)
        self.assertIn("SigLevel = PackageOptional DatabaseRequired", output)
        self.assertNotIn("https://old.example", output)
        self.assertIn(HEADER, output)
        again, repeated = self.rewrite(output)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(repeated, output, "rewrite must be idempotent")
        return output

    def test_arch_only(self):
        self.check_rewrite(HEADER + CORE, ["womarchy", "core"])

    def test_omarchy_before_core(self):
        output = self.check_rewrite(HEADER + OMARCHY + CORE, ["womarchy", "omarchy", "core"])
        self.assertIn(OMARCHY, output)
        self.assertIn(CORE, output)

    def test_existing_womarchy_after_omarchy(self):
        self.check_rewrite(HEADER + OMARCHY + OLD + CORE, ["womarchy", "omarchy", "core"])

    def test_existing_womarchy_first(self):
        self.check_rewrite(HEADER + OLD + OMARCHY + CORE, ["womarchy", "omarchy", "core"])

    def test_custom_repo_before_omarchy(self):
        custom = "[custom]\nServer = https://custom.example\n\n"
        self.check_rewrite(HEADER + custom + OMARCHY + CORE,
                           ["womarchy", "custom", "omarchy", "core"])

    def test_missing_core_does_not_replace_configuration(self):
        for content in (HEADER, HEADER + OMARCHY, HEADER + OLD):
            with self.subTest(content=content):
                result, output = self.rewrite(content)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no [core] section", result.stderr)
                self.assertEqual(output, content)


if __name__ == "__main__":
    unittest.main()
