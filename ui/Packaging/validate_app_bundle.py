#!/usr/bin/env python3
"""Validate a packaged Chronoframe macOS app bundle."""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable


@dataclass
class SignatureInspection:
    available: bool
    kind: str
    identifier: str | None
    team_identifier: str | None
    sealed_resources: bool
    hardened_runtime: bool
    timestamped: bool
    authorities: list[str] = field(default_factory=list)
    output: str = ""


@dataclass
class GatekeeperInspection:
    status: str
    returncode: int
    output: str


@dataclass
class BundleValidationResult:
    bundle_path: str
    bundle_identifier: str | None
    executable_path: str | None
    info_plist_path: str | None
    distribution_ready: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    signature: SignatureInspection | None = None
    gatekeeper: GatekeeperInspection | None = None


def _extract_prefixed_value(output: str, prefix: str) -> str | None:
    for line in output.splitlines():
        if line.startswith(prefix):
            return line.split("=", 1)[1].strip()
    return None


def inspect_codesign(app_path: Path) -> SignatureInspection:
    result = subprocess.run(
        ["codesign", "-dvvv", "--entitlements", ":-", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        return SignatureInspection(
            available=False,
            kind="unsigned",
            identifier=None,
            team_identifier=None,
            sealed_resources=False,
            hardened_runtime=False,
            timestamped=False,
            output=output,
        )

    authorities = [
        line.split("=", 1)[1].strip()
        for line in output.splitlines()
        if line.startswith("Authority=")
    ]
    kind = "unknown"
    if "Signature=adhoc" in output:
        kind = "adhoc"
    elif any(authority.startswith("Developer ID Application:") for authority in authorities):
        kind = "developer-id"

    return SignatureInspection(
        available=True,
        kind=kind,
        identifier=_extract_prefixed_value(output, "Identifier"),
        team_identifier=_extract_prefixed_value(output, "TeamIdentifier"),
        sealed_resources="Sealed Resources version=2" in output,
        hardened_runtime="Runtime Version=" in output,
        timestamped="Timestamp=" in output or "Signed Time=" in output,
        authorities=authorities,
        output=output,
    )


def inspect_gatekeeper(app_path: Path) -> GatekeeperInspection:
    result = subprocess.run(
        ["spctl", "-a", "-vv", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    output = (result.stdout + result.stderr).strip()

    if result.returncode == 0:
        status = "accepted"
    elif "rejected" in output.lower():
        status = "rejected"
    else:
        status = "unavailable"

    return GatekeeperInspection(status=status, returncode=result.returncode, output=output)


def validate_app_bundle(
    app_path: Path,
    *,
    require_distribution_signing: bool = False,
    codesign_inspector: Callable[[Path], SignatureInspection] = inspect_codesign,
    gatekeeper_inspector: Callable[[Path], GatekeeperInspection] = inspect_gatekeeper,
) -> BundleValidationResult:
    result = BundleValidationResult(
        bundle_path=str(app_path),
        bundle_identifier=None,
        executable_path=None,
        info_plist_path=None,
        distribution_ready=False,
    )

    if not app_path.exists():
        result.errors.append(f"Bundle does not exist: {app_path}")
        return result

    if not app_path.is_dir():
        result.errors.append(f"Bundle path is not a directory: {app_path}")
        return result

    info_plist_path = app_path / "Contents" / "Info.plist"
    result.info_plist_path = str(info_plist_path)
    if not info_plist_path.exists():
        result.errors.append(f"Missing Info.plist: {info_plist_path}")
        return result

    with info_plist_path.open("rb") as handle:
        info = plistlib.load(handle)

    result.bundle_identifier = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not executable_name:
        result.errors.append("Info.plist is missing CFBundleExecutable.")
    else:
        executable_path = app_path / "Contents" / "MacOS" / executable_name
        result.executable_path = str(executable_path)
        if not executable_path.exists():
            result.errors.append(f"Missing app executable: {executable_path}")

    if info.get("CFBundleIconFile") != "AppIcon":
        result.errors.append("Info.plist must declare CFBundleIconFile=AppIcon.")

    if info.get("CFBundlePackageType") != "APPL":
        result.errors.append("Info.plist must declare CFBundlePackageType=APPL.")

    required_files = [
        app_path / "Contents" / "Resources" / "AppIcon.icns",
        app_path / "Contents" / "Resources" / "Backend" / "chronoframe.py",
        app_path / "Contents" / "Resources" / "Backend" / "requirements.txt",
        app_path / "Contents" / "Resources" / "Backend" / "chronoframe" / "core.py",
    ]
    for required_file in required_files:
        if not required_file.exists():
            result.errors.append(f"Missing packaged resource: {required_file}")

    signature = codesign_inspector(app_path)
    result.signature = signature

    if not signature.available:
        result.errors.append("codesign inspection failed for the app bundle.")
    else:
        if result.bundle_identifier and signature.identifier and signature.identifier != result.bundle_identifier:
            result.errors.append(
                "Code signature identifier does not match Info.plist bundle identifier."
            )
        if not signature.sealed_resources:
            result.errors.append("Bundle resources are not sealed by the code signature.")

        if require_distribution_signing:
            if signature.kind != "developer-id":
                result.errors.append(
                    "Distribution validation requires a Developer ID Application signature."
                )
            if not signature.hardened_runtime:
                result.errors.append(
                    "Distribution validation requires hardened runtime to be enabled."
                )
            if not signature.timestamped:
                result.errors.append(
                    "Distribution validation requires a timestamped code signature."
                )
        elif signature.kind == "adhoc":
            result.warnings.append(
                "Bundle is ad hoc signed for local validation only; Developer ID signing is still required for notarization."
            )
        elif signature.kind == "unsigned":
            result.errors.append("Bundle is unsigned.")

    gatekeeper = gatekeeper_inspector(app_path)
    result.gatekeeper = gatekeeper
    if gatekeeper.status == "rejected":
        if require_distribution_signing:
            result.warnings.append(
                "Gatekeeper currently rejects the bundle; notarization may still be pending."
            )
        else:
            result.warnings.append(
                "Gatekeeper rejects the local bundle, which is expected for ad hoc-signed development builds."
            )
    elif gatekeeper.status == "unavailable" and gatekeeper.output:
        result.warnings.append(
            "Gatekeeper assessment was unavailable on this machine; inspect the output for details."
        )

    result.distribution_ready = (
        not result.errors
        and signature.available
        and signature.kind == "developer-id"
        and signature.hardened_runtime
        and signature.timestamped
    )
    return result


def _print_human_readable(result: BundleValidationResult) -> None:
    status = "PASS" if not result.errors else "FAIL"
    print(f"Bundle validation: {status}")
    print(f"Bundle: {result.bundle_path}")
    print(f"Identifier: {result.bundle_identifier or 'unknown'}")
    if result.signature is not None:
        print(f"Signature: {result.signature.kind}")
        print(f"Hardened runtime: {'yes' if result.signature.hardened_runtime else 'no'}")
        print(f"Sealed resources: {'yes' if result.signature.sealed_resources else 'no'}")
    if result.gatekeeper is not None:
        print(f"Gatekeeper: {result.gatekeeper.status}")

    if result.errors:
        print("Errors:")
        for message in result.errors:
            print(f"  - {message}")

    if result.warnings:
        print("Warnings:")
        for message in result.warnings:
            print(f"  - {message}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_path", help="Path to the .app bundle to validate.")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the validation result as JSON.",
    )
    parser.add_argument(
        "--require-distribution-signing",
        action="store_true",
        help="Require Developer ID signing, hardened runtime, and a timestamped signature.",
    )
    args = parser.parse_args(argv)

    result = validate_app_bundle(
        Path(args.app_path),
        require_distribution_signing=args.require_distribution_signing,
    )

    if args.json:
        json.dump(asdict(result), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        _print_human_readable(result)

    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
