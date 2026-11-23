#!/usr/bin/env python3
"""Compatibility entry point for existing CMO setup commands."""
from pathlib import Path
import runpy
import sys

if __name__ == "__main__":
    sys.argv.extend(["--feature", "cmo"])
    runpy.run_path(str(Path(__file__).with_name("install-feature-control.py")), run_name="__main__")
