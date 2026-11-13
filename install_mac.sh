#!/bin/bash
set -euo pipefail

# Install Apple's build tools and continue when their installer finishes.
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install
    echo "Installing Apple command-line tools. Complete the installation dialog; setup will continue automatically."
    until xcode-select -p >/dev/null 2>&1 && xcrun swift --version >/dev/null 2>&1; do
        sleep 5
    done
fi

INSTALL_TMP=$(mktemp -d)
trap 'rm -rf "$INSTALL_TMP"' EXIT
curl -fL https://github.com/AryaDesai/DriftCorrect/archive/refs/heads/z-correction.zip -o "$INSTALL_TMP/DriftCorrect.zip"
ditto -xk "$INSTALL_TMP/DriftCorrect.zip" "$INSTALL_TMP"
bash "$INSTALL_TMP/DriftCorrect-z-correction/DriftCorrect_mac/scripts/bundle_app.sh"
mkdir -p "$HOME/Applications"
ditto "$INSTALL_TMP/DriftCorrect-z-correction/DriftCorrect_mac/build/DriftCorrect.app" "$HOME/Applications/DriftCorrect.app"
echo "Installed. Launch DriftCorrect from your Applications folder."
open "$HOME/Applications/DriftCorrect.app"
