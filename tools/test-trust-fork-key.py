#!/usr/bin/env python3
"""Exercise trust setup with fake tools; never touch a real keyring or use sudo."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FPR = "E0294A6FFD4CC7FF61F86F0BB0EE0B3F4029644C"

FAKE_TOOL = r'''
from pathlib import Path
import os
import sys

name = Path(sys.argv[0]).name
mode = os.environ.get("MODE", "good")
if name == "sudo":
    os.execvp(sys.argv[1], sys.argv[1:])
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(name + " " + " ".join(sys.argv[1:]) + "\n")
if name == "curl":
    if mode == "download-failure":
        sys.exit(22)
    Path(sys.argv[sys.argv.index("-o") + 1]).write_text("mock public key")
elif name == "gpg":
    assert Path(sys.argv[-1]).read_text() == "mock public key"
    if mode == "invalid-key":
        sys.exit(2)
    fpr = os.environ["EXPECTED_FPR"] if mode != "wrong-key" else "0" * 40
    print("pub:::::::::")
    print("fpr:::::::::" + fpr + ":")
    # Subkey fingerprints do not affect the primary-key check.
    print("sub:::::::::")
    print("fpr:::::::::" + "1" * 40 + ":")
    if mode == "extra-key":
        print("pub:::::::::")
        print("fpr:::::::::" + "2" * 40 + ":")
elif name == "pacman-key":
    if mode == "import-failure" and sys.argv[1] == "--add":
        sys.exit(1)
    if sys.argv[1] == "--add":
        assert Path(sys.argv[2]).read_text() == "mock public key"
    else:
        assert sys.argv[1:] == ["--lsign-key", os.environ["EXPECTED_FPR"]]
'''


class TrustForkKeyTests(unittest.TestCase):
    def run_script(self, mode="good", *args):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            bindir = base / "bin"
            bindir.mkdir()
            work = base / "work"
            work.mkdir()
            for name in ("curl", "gpg", "pacman-key", "sudo"):
                stub = bindir / name
                stub.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
                stub.chmod(0o755)
            log = base / "calls"
            result = subprocess.run(
                ["bash", str(ROOT / "tools/trust-fork-key.sh"), *args],
                env={**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}",
                     "CALL_LOG": str(log), "EXPECTED_FPR": FPR,
                     "TMPDIR": str(work), "MODE": mode},
                capture_output=True, text=True,
            )
            calls = log.read_text() if log.exists() else ""
            self.assertEqual(list(work.iterdir()), [], "temporary key files leaked")
            return result, calls

    def test_verified_key_is_imported_then_signed(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        actions = [line for line in calls.splitlines() if line.startswith("pacman-key ")]
        self.assertEqual(len(actions), 2)
        self.assertTrue(actions[0].startswith("pacman-key --add "))
        self.assertEqual(actions[1], f"pacman-key --lsign-key {FPR}")
        self.assertIn("Repository configuration is unchanged", result.stdout)

    def test_wrong_or_additional_primary_keys_are_rejected(self):
        for mode in ("wrong-key", "extra-key"):
            with self.subTest(mode=mode):
                result, calls = self.run_script(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fingerprint mismatch", result.stderr)
                self.assertNotIn("pacman-key ", calls)

    def test_download_or_parse_failure_never_imports(self):
        for mode in ("download-failure", "invalid-key"):
            with self.subTest(mode=mode):
                result, calls = self.run_script(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("pacman-key ", calls)

    def test_import_failure_stops_before_signing(self):
        result, calls = self.run_script("import-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pacman-key --add ", calls)
        self.assertNotIn("--lsign-key", calls)
        self.assertNotIn("locally trusted", result.stdout)

    def test_help_is_offline_and_mutation_free(self):
        result, calls = self.run_script("good", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "")

    def test_unexpected_arguments_fail_offline(self):
        result, calls = self.run_script("good", "--unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
