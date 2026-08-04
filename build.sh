#!/usr/bin/env bash
# ============================================================
# build.sh — Build & deploy FS25_SeasonalCropStress
# Usage:
#   bash build.sh            — builds zip only
#   bash build.sh --deploy   — builds zip AND copies to mods folder
# ============================================================

set -e

MOD_NAME="FS25_SeasonalCropStress"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/.."
ZIP_PATH="$OUTPUT_DIR/${MOD_NAME}.zip"

# Windows path for mods folder (adjust if needed)
MODS_DIR="$USERPROFILE/Documents/My Games/FarmingSimulator2025/mods"

echo "============================================"
echo "  Building $MOD_NAME"
echo "============================================"

# Remove old zip
if [ -f "$ZIP_PATH" ]; then
    rm "$ZIP_PATH"
    echo "  Removed old zip"
fi

# Build new zip — must use forward slashes inside (FS25 requirement)
# PowerShell Compress-Archive creates backslash paths — use 'zip' or this python fallback
cd "$SCRIPT_DIR"

if command -v zip &>/dev/null; then
    # Paths inside zip are relative to CWD (already cd'd to SCRIPT_DIR).
    # Exclude patterns must use the same relative form.
    zip -r "$ZIP_PATH" . \
        --exclude "./*.sh" \
        --exclude "./.claude/*" \
        --exclude "./.git/*" \
        --exclude "./*.md" \
        --exclude "./.gitignore" \
        --exclude "./__MACOSX/*" \
        --exclude "./*.DS_Store" \
        --exclude "./*.zip"
        --exclude "./tools/*" 
    echo "  Built via zip"
else
    # Python fallback — try python3 first, then Windows launcher (py)
    PYTHON_CMD=""
    if command -v python3 &>/dev/null; then PYTHON_CMD="python3"
    elif command -v py &>/dev/null; then PYTHON_CMD="py"
    else echo "ERROR: no Python found (need python3 or py)"; exit 1
    fi
    $PYTHON_CMD - <<'PYEOF'
import zipfile, os, sys

MOD_DIR = os.getcwd()
ZIP_PATH = os.path.join(os.path.dirname(MOD_DIR), os.path.basename(MOD_DIR) + ".zip")

EXCLUDE_DIRS  = {".git", ".claude", "__MACOSX", "node_modules", "tools/test"}
EXCLUDE_EXTS  = {".sh", ".md", ".DS_Store", ".zip"}
EXCLUDE_FILES = {".gitignore"}

def rel(path):
    return os.path.relpath(path, MOD_DIR).replace("\\", "/")

with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(MOD_DIR):
        # Prune excluded dirs in-place (match by full relative path)
        dirs[:] = [d for d in dirs if rel(os.path.join(root, d)) not in EXCLUDE_DIRS]
        for fname in files:
            if fname in EXCLUDE_FILES:
                continue
            if any(fname.endswith(ext) for ext in EXCLUDE_EXTS):
                continue
            full_path = os.path.join(root, fname)
            # Paths relative to MOD_DIR → files land at ZIP root (not in a subfolder)
            arc_name = rel(full_path)
            # Enforce forward slashes (FS25 requirement)
            arc_name = arc_name.replace("\\", "/")
            zf.write(full_path, arc_name)
            print(f"  + {arc_name}")

print(f"\n  ZIP created: {ZIP_PATH}")
PYEOF
fi

echo ""
echo "  Output: $ZIP_PATH"

# --deploy flag: copy zip to mods folder
if [[ "$1" == "--deploy" ]]; then
    echo ""
    echo "  Deploying to mods folder..."

    if [ ! -d "$MODS_DIR" ]; then
        echo "  WARNING: Mods folder not found at: $MODS_DIR"
        echo "  Edit MODS_DIR in build.sh if your path differs."
        exit 1
    fi

    # Remove old deployed version
    if [ -f "$MODS_DIR/${MOD_NAME}.zip" ]; then
        rm "$MODS_DIR/${MOD_NAME}.zip"
    fi

    cp "$ZIP_PATH" "$MODS_DIR/${MOD_NAME}.zip"
    echo "  Deployed: $MODS_DIR/${MOD_NAME}.zip"
fi

echo ""
echo "  Done. Check log.txt for [CropStress] entries after launching."
echo "============================================"
