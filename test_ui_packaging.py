#!/usr/bin/env python3
"""Unit tests for macOS app bundle packaging validation."""

from __future__ import annotations

import importlib.util
import contextlib
import io
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def test_inspect_codesign_parses_developer_id_output(self):
        output = "\n".join(
            [
                "Identifier=com.nishith.chronoframe",
                "TeamIdentifier=ABCDE12345",
                "Authority=Developer ID Application: Example (ABCDE12345)",
                "Authority=Developer ID Certification Authority",
                "Sealed Resources version=2 rules=13 files=7",
                "Runtime Version=14.0.0",
                "Timestamp=Apr 25, 2026 at 12:00:00 PM",
            ]
        )

        with mock.patch.object(
            validator.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["codesign"], 0, stdout="", stderr=output),
        ):
            inspection = validator.inspect_codesign(Path("/tmp/Chronoframe.app"))

        self.assertTrue(inspection.available)
        self.assertEqual(inspection.kind, "developer-id")
        self.assertEqual(inspection.identifier, "com.nishith.chronoframe")
        self.assertEqual(inspection.team_identifier, "ABCDE12345")
        self.assertTrue(inspection.sealed_resources)
        self.assertTrue(inspection.hardened_runtime)
        self.assertTrue(inspection.timestamped)
        self.assertEqual(inspection.authorities[0], "Developer ID Application: Example (ABCDE12345)")

    def test_inspect_codesign_reportsUnsignedWhenCommandFails(self):
        with mock.patch.object(
            validator.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["codesign"], 1, stdout="", stderr="not signed"),
        ):
            inspection = validator.inspect_codesign(Path("/tmp/Chronoframe.app"))

        self.assertFalse(inspection.available)
        self.assertEqual(inspection.kind, "unsigned")
        self.assertFalse(inspection.sealed_resources)
        self.assertIn("not signed", inspection.output)

    def test_inspect_codesign_parses_adhoc_output_without_prefixed_values(self):
        self.assertIsNone(validator._extract_prefixed_value("Authority=Local", "Identifier"))

        with mock.patch.object(
            validator.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(
                ["codesign"],
                0,
                stdout="",
                stderr="Signature=adhoc\nSealed Resources version=2 rules=13 files=7",
            ),
        ):
            inspection = validator.inspect_codesign(Path("/tmp/Chronoframe.app"))

        self.assertTrue(inspection.available)
        self.assertEqual(inspection.kind, "adhoc")
        self.assertIsNone(inspection.identifier)
        self.assertIsNone(inspection.team_identifier)

    def test_inspect_gatekeeper_classifiesAcceptedRejectedAndUnavailable(self):
        cases = [
            (0, "accepted", "accepted"),
            (3, "rejected", "rejected"),
            (2, "assessment unavailable", "unavailable"),
        ]

        for returncode, output, expected_status in cases:
            with self.subTest(expected_status=expected_status):
                with mock.patch.object(
                    validator.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(["spctl"], returncode, stdout="", stderr=output),
                ):
                    inspection = validator.inspect_gatekeeper(Path("/tmp/Chronoframe.app"))

                self.assertEqual(inspection.status, expected_status)
                self.assertEqual(inspection.returncode, returncode)
                self.assertEqual(inspection.output, output)

    def test_validationReportsMissingBundleDirectoryAndInfoPlist(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            missing = root / "Missing.app"
            result = validator.validate_app_bundle(missing)
            self.assertTrue(any("does not exist" in error for error in result.errors))

            plain_file = root / "Chronoframe.app"
            plain_file.write_text("not a directory")
            result = validator.validate_app_bundle(plain_file)
            self.assertTrue(any("not a directory" in error for error in result.errors))

            bundle_without_info = root / "NoInfo.app"
            bundle_without_info.mkdir()
            result = validator.validate_app_bundle(bundle_without_info)
            self.assertTrue(any("Missing Info.plist" in error for error in result.errors))

    def test_validationReportsMalformedInfoAndSignatureProblems(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))
            info_path = app_path / "Contents" / "Info.plist"
            with info_path.open("wb") as handle:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "com.nishith.chronoframe",
                        "CFBundleIconFile": "WrongIcon",
                        "CFBundlePackageType": "BNDL",
                    },
                    handle,
                )

            result = validator.validate_app_bundle(
                app_path,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=False,
                    kind="unsigned",
                    identifier=None,
                    team_identifier=None,
                    sealed_resources=False,
                    hardened_runtime=False,
                    timestamped=False,
                    output="code object is not signed",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="unavailable",
                    returncode=2,
                    output="spctl is unavailable",
                ),
            )

        self.assertTrue(any("missing CFBundleExecutable" in error for error in result.errors))
        self.assertTrue(any("CFBundleIconFile=AppIcon" in error for error in result.errors))
        self.assertTrue(any("CFBundlePackageType=APPL" in error for error in result.errors))
        self.assertTrue(any("codesign inspection failed" in error for error in result.errors))
        self.assertTrue(any("Gatekeeper assessment was unavailable" in warning for warning in result.warnings))

    def test_validationReportsMissingExecutableNamedByInfoPlist(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))
            (app_path / "Contents" / "MacOS" / "Chronoframe").unlink()

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

        self.assertTrue(any("Missing app executable" in error for error in result.errors))

    def test_validationReportsSignatureIdentifierMismatchAndUnsealedResources(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))

            result = validator.validate_app_bundle(
                app_path,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=True,
                    kind="unknown",
                    identifier="com.example.other",
                    team_identifier="ABCDE12345",
                    sealed_resources=False,
                    hardened_runtime=False,
                    timestamped=False,
                    output="Identifier=com.example.other",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="accepted",
                    returncode=0,
                    output="accepted",
                ),
            )

        self.assertTrue(any("identifier does not match" in error for error in result.errors))
        self.assertTrue(any("resources are not sealed" in error for error in result.errors))

    def test_validationReportsUnsignedAvailableSignature(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            app_path = self._create_minimal_app_bundle(Path(tmp_dir))

            result = validator.validate_app_bundle(
                app_path,
                codesign_inspector=lambda _: validator.SignatureInspection(
                    available=True,
                    kind="unsigned",
                    identifier="com.nishith.chronoframe",
                    team_identifier=None,
                    sealed_resources=True,
                    hardened_runtime=False,
                    timestamped=False,
                    output="unsigned",
                ),
                gatekeeper_inspector=lambda _: validator.GatekeeperInspection(
                    status="accepted",
                    returncode=0,
                    output="accepted",
                ),
            )

        self.assertTrue(any("Bundle is unsigned" in error for error in result.errors))

    def test_mainEmitsJsonAndFailureExitCode(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            missing_app = Path(tmp_dir) / "Missing.app"
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = validator.main([str(missing_app), "--json"])

        self.assertEqual(exit_code, 1)
        self.assertIn('"distribution_ready": false', output.getvalue())
        self.assertIn("Bundle does not exist", output.getvalue())

    def test_mainEmitsHumanReadableErrorsAndWarnings(self):
        fake_result = validator.BundleValidationResult(
            bundle_path="/tmp/Chronoframe.app",
            bundle_identifier="com.nishith.chronoframe",
            executable_path="/tmp/Chronoframe.app/Contents/MacOS/Chronoframe",
            info_plist_path="/tmp/Chronoframe.app/Contents/Info.plist",
            distribution_ready=False,
            errors=["Missing packaged resource: Backend/chronoframe.py"],
            warnings=["Gatekeeper assessment was unavailable"],
            signature=validator.SignatureInspection(
                available=True,
                kind="adhoc",
                identifier="com.nishith.chronoframe",
                team_identifier=None,
                sealed_resources=True,
                hardened_runtime=False,
                timestamped=False,
                output="Signature=adhoc",
            ),
            gatekeeper=validator.GatekeeperInspection(
                status="unavailable",
                returncode=2,
                output="spctl unavailable",
            ),
        )
        output = io.StringIO()

        with mock.patch.object(validator, "validate_app_bundle", return_value=fake_result):
            with contextlib.redirect_stdout(output):
                exit_code = validator.main(["/tmp/Chronoframe.app"])

        text = output.getvalue()
        self.assertEqual(exit_code, 1)
        self.assertIn("Bundle validation: FAIL", text)
        self.assertIn("Signature: adhoc", text)
        self.assertIn("Gatekeeper: unavailable", text)
        self.assertIn("Errors:", text)
        self.assertIn("Warnings:", text)


if __name__ == "__main__":
    unittest.main()
