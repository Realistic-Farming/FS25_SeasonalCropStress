#!/usr/bin/env python3
"""
build.py - Build & deploy FS25_SeasonalCropStress

Usage:
    python build.py            builds zip only
    python build.py --deploy   builds zip AND copies to mods folder

Packaging mirrors the legacy build.sh python fallback exactly: same
exclusion sets, forward-slash entry paths (FS25 silently rejects zips
with backslash separators on load). Never use PowerShell Compress-Archive.
"""

import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

MOD_NAME = "FS25_SeasonalCropStress"
MOD_DIR = Path(__file__).parent.resolve()
ZIP_PATH = MOD_DIR / f"{MOD_NAME}.zip"

MODS_DIR = Path.home() / "Documents" / "My Games" / "FarmingSimulator2025" / "mods"

# Vera F2 2026-08-04: build.sh python fallback only excluded tools/test and
# shipped 27 junk entries (all of tools/, the stale _reference_esc_pre_greenfield
# chrome tree, icon sources, LICENSE). Target zip shape = the clean 1.2.5.1
# entry set (85 entries; .github templates stay, they were in that baseline).
EXCLUDE_DIRS = {".git", ".claude", "__MACOSX", "node_modules", "tools", "_reference_esc_pre_greenfield"}
EXCLUDE_EXTS = {".sh", ".md", ".DS_Store", ".zip"}
EXCLUDE_FILES = {".gitignore", "build.py", "icon_preview.png", "icon_source.png", "LICENSE"}


def read_version():
    try:
        text = (MOD_DIR / "modDesc.xml").read_text(encoding="utf-8")
        m = re.search(r"<version>([^<]+)</version>", text)
        return m.group(1) if m else "?"
    except OSError:
        return "?"


def rel(path):
    return os.path.relpath(path, MOD_DIR).replace("\\", "/")


def build_zip():
    print("============================================")
    print(f"  Building {MOD_NAME} v{read_version()}")
    print("============================================")

    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
        print("  Removed old zip")

    file_count = 0
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(MOD_DIR):
            dirs[:] = [d for d in dirs if rel(os.path.join(root, d)) not in EXCLUDE_DIRS]
            for fname in files:
                if fname in EXCLUDE_FILES:
                    continue
                if any(fname.endswith(ext) for ext in EXCLUDE_EXTS):
                    continue
                full_path = os.path.join(root, fname)
                arc_name = rel(full_path)
                zf.write(full_path, arc_name)
                file_count += 1

    size_kb = ZIP_PATH.stat().st_size / 1024
    print(f"  ZIP created: {ZIP_PATH} ({size_kb:.0f} KB, {file_count} files)")


def deploy():
    print("  Deploying to mods folder...")
    if not MODS_DIR.exists():
        print(f"  WARNING: Mods folder not found at: {MODS_DIR}")
        sys.exit(1)

    dest = MODS_DIR / f"{MOD_NAME}.zip"
    if dest.exists():
        dest.unlink()
    shutil.copy2(ZIP_PATH, dest)
    print(f"  Deployed: {dest}")


if __name__ == "__main__":
    build_zip()
    if "--deploy" in sys.argv:
        deploy()
    print("  Done. Check log.txt for [CropStress] entries after launching.")
    print("============================================")
