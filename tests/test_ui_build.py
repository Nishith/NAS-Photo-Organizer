#!/usr/bin/env python3
"""Smoke tests for the packaged macOS app bundle."""

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest


class TestXcodeProjectMembership(unittest.TestCase):
    def test_swift_app_sources_are_listed_in_xcode_project(self):
        repo_root = os.path.dirname(os.path.dirname(__file__))
        project_file = os.path.join(repo_root, "ui", "Chronoframe.xcodeproj", "project.pbxproj")
        sources_root = os.path.join(repo_root, "ui", "Sources")

        with open(project_file, "r", encoding="utf-8") as handle:
            project = handle.read()

        missing = []
        for root, _, filenames in os.walk(sources_root):
            if ".build" in root.split(os.sep):
                continue
            for filename in filenames:
                if filename.endswith(".swift") and filename not in project:
                    missing.append(os.path.relpath(os.path.join(root, filename), repo_root))

        self.assertEqual(missing, [])


@unittest.skipUnless(sys.platform == "darwin", "macOS build smoke requires macOS")
class TestUIBuildPipeline(unittest.TestCase):
    def test_build_script_stages_bundle_with_icon_and_backend(self):
        repo_root = os.path.dirname(os.path.dirname(__file__))
        ui_dir = os.path.join(repo_root, "ui")
        project_path = os.path.join(ui_dir, "Chronoframe.xcodeproj")

        self.assertTrue(os.path.isdir(project_path), project_path)

        listing = subprocess.run(
            ["xcodebuild", "-list", "-project", project_path],
            cwd=ui_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            listing.returncode,
            0,
            msg=f"xcodebuild -list failed\nSTDOUT:\n{listing.stdout}\nSTDERR:\n{listing.stderr}",
        )
        self.assertIn("ChronoframeApp", listing.stdout)
        self.assertIn("ChronoframeAppTests", listing.stdout)
        self.assertIn("ChronoframeUITests", listing.stdout)
        self.assertIn("Chronoframe", listing.stdout)

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

        validation = subprocess.run(
            [
                sys.executable,
                os.path.join(ui_dir, "Packaging", "validate_app_bundle.py"),
                "--json",
                app_dir,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(validation.returncode, 0, msg=validation.stderr or validation.stdout)
        validation_result = json.loads(validation.stdout)
        self.assertEqual(validation_result["errors"], [])
        self.assertEqual(validation_result["signature"]["kind"], "adhoc")
        self.assertTrue(validation_result["signature"]["sealed_resources"])

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

    def test_build_script_failure_points_to_xcodebuild_log(self):
        repo_root = os.path.dirname(os.path.dirname(__file__))
        ui_dir = os.path.join(repo_root, "ui")
        log_path = os.path.join(ui_dir, "build", "xcodebuild.log")

        with tempfile.TemporaryDirectory() as temp_dir:
            fake_xcodebuild = os.path.join(temp_dir, "xcodebuild")
            with open(fake_xcodebuild, "w", encoding="utf-8") as handle:
                handle.write("#!/bin/sh\n")
                handle.write("echo 'fake xcodebuild failure from test harness' >&2\n")
                handle.write("exit 42\n")
            os.chmod(fake_xcodebuild, 0o755)

            env = os.environ.copy()
            env["PATH"] = temp_dir + os.pathsep + env["PATH"]

            result = subprocess.run(
                ["bash", "build.sh"],
                cwd=ui_dir,
                capture_output=True,
                text=True,
                check=False,
                env=env,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(os.path.exists(log_path), log_path)
        combined_output = result.stdout + result.stderr
        self.assertIn("xcodebuild.log", combined_output)
        with open(log_path, "r", encoding="utf-8") as handle:
            contents = handle.read()
        self.assertIn("fake xcodebuild failure from test harness", contents)


if __name__ == "__main__":
    unittest.main()
