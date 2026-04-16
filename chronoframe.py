#!/usr/bin/env python3
"""
Chronoframe - Setup Wrapper
"""

import sys
import os
import json
import subprocess
import importlib.util

DEPENDENCY_MODULES = {
    "exifread": "exifread",
    "tenacity": "tenacity",
    "rich": "rich",
    "yaml": "pyyaml",
}


def dependency_status():
    missing = []
    for module_name, package_name in DEPENDENCY_MODULES.items():
        if importlib.util.find_spec(module_name) is None:
            missing.append(package_name)
    return {"ok": not missing, "missing": missing}


def check_and_install_dependencies(noninteractive=None):
    req_path = os.path.join(os.path.dirname(__file__), "requirements.txt")
    status = dependency_status()
    missing = status["missing"]

    if noninteractive is None:
        noninteractive = os.environ.get("CHRONOFRAME_NONINTERACTIVE", "").lower() in {"1", "true", "yes"}

    if missing:
        print(f"Missing essential packages: {', '.join(missing)}")
        if noninteractive:
            print("Running in non-interactive mode. Please install the requirements before launching Chronoframe.")
            sys.exit(1)
        if not os.path.exists(req_path):
            print("requirements.txt was not found. Please install the packages manually.")
            sys.exit(1)

        ans = input("Would you like to auto-install these using your active python pip? [y/N]: ")
        if ans.lower() in ['y', 'yes']:
            print("Installing dependencies...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", "-r", req_path])
            print("Installation complete!\n")
            return dependency_status()
        else:
            print("Please manually install the requirements to run the organizer.")
            sys.exit(1)

    return status


if __name__ == "__main__":
    if "--check-deps-json" in sys.argv[1:]:
        print(json.dumps(dependency_status()))
        sys.exit(0)

    check_and_install_dependencies()
    # Import the actual module now that dependencies are verified
    from chronoframe import __main__
    __main__.main()
