#!/usr/bin/env python3
"""Unit tests for macOS app bundle packaging validation."""

from __future__ import annotations

import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


def _load_validator_module():
    repo_root = Path(__file__).resolve().parent
    module_path = repo_root / "ui" / "Packaging" / "validate_app_bundle.py"
    spec = importlib.util.spec_from_file_location("validate_app_bundle", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


validator = _load_validator_module()


class TestAppBundleValidator(unittest.TestCase):
    def _create_minimal_app_bundle(self, root: Path) -> Path:
        app_path = root / "Chronoframe.app"
        executable_path = app_path / "Contents" / "MacOS" / "Chronoframe"
        resources_path = app_path / "Contents" / "Resources"
        backend_path = resources_path / "Backend"

        executable_path.parent.mkdir(parents=True)
        backend_path.mkdir(parents=True)
        (backend_path / "chronoframe").mkdir(parents=True)

        with (app_path / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleExecutable": "Chronoframe",
                    "CFBundleIdentifier": "com.nishith.chronoframe",
                    "CFBundleIconFile": "AppIcon",
                    "CFBundlePackageType": "APPL",
                },
                handle,
            )

        executable_path.write_text("binary")
        (resources_path / "AppIcon.icns").write_text("icon")
        (backend_path / "chronoframe.py").write_text("print('hi')")
        (backend_path / "requirements.txt").write_text("rich")
        (backend_path / "chronoframe" / "core.py").write_text("# core")
        return app_path

    def test_local_validation_accepts_adhoc_bundle_with_warning(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))

            result = validator.validate_app_bundle(
                app_path,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=True,
                    kind="adhoc",
                    identifier="com.nishith.chronoframe",
                    team_identifier=None,
                    sealed_resources=True,
                    hardened_runtime=False,
                    timestamped=False,
                    output="Signature=adhoc",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="rejected",
                    returncode=1,
                    output="rejected",
                ),
            )

        self.assertEqual(result.errors, [])
        self.assertFalse(result.distribution_ready)
        self.assertTrue(any("ad hoc signed" in warning for warning in result.warnings))

    def test_distribution_validation_requires_developer_id_signature(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))

            result = validator.validate_app_bundle(
                app_path,
                require_distribution_signing=True,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=True,
                    kind="adhoc",
                    identifier="com.nishith.chronoframe",
                    team_identifier=None,
                    sealed_resources=True,
                    hardened_runtime=False,
                    timestamped=False,
                    output="Signature=adhoc",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="rejected",
                    returncode=1,
                    output="rejected",
                ),
            )

        self.assertTrue(any("Developer ID Application signature" in error for error in result.errors))
        self.assertTrue(any("hardened runtime" in error for error in result.errors))
        self.assertTrue(any("timestamped" in error for error in result.errors))

    def test_distribution_validation_accepts_developer_id_bundle(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))

            result = validator.validate_app_bundle(
                app_path,
                require_distribution_signing=True,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=True,
                    kind="developer-id",
                    identifier="com.nishith.chronoframe",
                    team_identifier="ABCDE12345",
                    sealed_resources=True,
                    hardened_runtime=True,
                    timestamped=True,
                    authorities=["Developer ID Application: Example (ABCDE12345)"],
                    output="Authority=Developer ID Application: Example (ABCDE12345)",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="rejected",
                    returncode=1,
                    output="not notarized yet",
                ),
            )

        self.assertEqual(result.errors, [])
        self.assertTrue(result.distribution_ready)
        self.assertTrue(any("notarization may still be pending" in warning for warning in result.warnings))

    def test_validation_reports_missing_packaged_resources(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))
            (app_path / "Contents" / "Resources" / "Backend" / "chronoframe.py").unlink()

            result = validator.validate_app_bundle(
                app_path,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=True,
                    kind="adhoc",
                    identifier="com.nishith.chronoframe",
                    team_identifier=None,
                    sealed_resources=True,
                    hardened_runtime=False,
                    timestamped=False,
                    output="Signature=adhoc",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="accepted",
                    returncode=0,
                    output="accepted",
                ),
            )

        self.assertTrue(any("chronoframe.py" in error for error in result.errors))


if __name__ == "__main__":
    unittest.main()
