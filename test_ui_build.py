#!/usr/bin/env python3
"""Smoke tests for the packaged macOS app bundle."""

import os
import plistlib
import subprocess
import sys
import unittest


@unittest.skipUnless(sys.platform == "darwin", "macOS build smoke requires macOS")
class TestUIBuildPipeline(unittest.TestCase):
    def test_build_script_stages_bundle_with_icon_and_backend(self):
        repo_root = os.path.dirname(__file__)
        ui_dir = os.path.join(repo_root, "ui")

        result = subprocess.run(
            ["bash", "build.sh"],
            cwd=ui_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"build.sh failed\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}",
        )

        app_dir = os.path.join(ui_dir, "build", "Chronoframe.app")
        plist_path = os.path.join(app_dir, "Contents", "Info.plist")
        executable_path = os.path.join(app_dir, "Contents", "MacOS", "Chronoframe")
        icon_path = os.path.join(app_dir, "Contents", "Resources", "AppIcon.icns")
        backend_dir = os.path.join(app_dir, "Contents", "Resources", "Backend")
        zip_path = os.path.join(ui_dir, "build", "Chronoframe.zip")

        self.assertTrue(os.path.exists(app_dir), app_dir)
        self.assertTrue(os.path.exists(plist_path), plist_path)
        self.assertTrue(os.path.exists(executable_path), executable_path)
        self.assertTrue(os.path.exists(icon_path), icon_path)
        self.assertTrue(os.path.exists(zip_path), zip_path)
        self.assertTrue(os.path.exists(os.path.join(backend_dir, "chronoframe.py")))
        self.assertTrue(os.path.exists(os.path.join(backend_dir, "requirements.txt")))
        self.assertTrue(os.path.exists(os.path.join(backend_dir, "chronoframe", "core.py")))

        with open(plist_path, "rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleExecutable"], "Chronoframe")
        self.assertEqual(info["CFBundleIdentifier"], "com.nishith.chronoframe")
        self.assertEqual(info["CFBundleIconFile"], "AppIcon")

        signature = subprocess.run(
            ["codesign", "-dvvv", app_dir],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(signature.returncode, 0, msg=signature.stderr)
        signature_output = signature.stdout + signature.stderr
        self.assertIn("Signature=adhoc", signature_output)
        self.assertIn("Sealed Resources version=2", signature_output)


if __name__ == "__main__":
    unittest.main()
