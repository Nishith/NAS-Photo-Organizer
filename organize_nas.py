#!/usr/bin/env python3
"""
NAS Photo Organizer - L7 Architected Setup Wrapper
"""

import sys
import os
import subprocess
import importlib.util

def check_and_install_dependencies():
    req_path = os.path.join(os.path.dirname(__file__), "requirements.txt")
    if not os.path.exists(req_path):
        return

    # Check if packages exist
    missing = []
    for pkg in ["exifread", "tenacity", "rich", "yaml"]:
        if importlib.util.find_spec(pkg) is None:
            # Note: pyyaml imports as 'yaml'
            missing.append(pkg if pkg != 'yaml' else 'pyyaml')

    if missing:
        print(f"Missing essential packages: {', '.join(missing)}")
        ans = input("Would you like to auto-install these using your active python pip? [y/N]: ")
        if ans.lower() in ['y', 'yes']:
            print("Installing dependencies...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", "-r", req_path])
            print("Installation complete!\n")
        else:
            print("Please manually install the requirements to run the organizer.")
            sys.exit(1)

if __name__ == "__main__":
    check_and_install_dependencies()
    # Import the actual module now that dependencies are verified
    from nas_organizer import __main__
    __main__.main()
