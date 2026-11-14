#!/bin/bash
set -euo pipefail

# Ensure Apple's command-line developer tools are available for building the app.
if ! xcode-select -p >/dev/null 2>&1; then
    # Open Apple's interactive installer if the tools are not installed.
    xcode-select --install
    echo "Installing Apple command-line tools. Complete the installation dialog; setup will continue automatically."
    # Wait until both the developer path and Swift toolchain are usable.
    until xcode-select -p >/dev/null 2>&1 && xcrun swift --version >/dev/null 2>&1; do
        sleep 5
    done
fi

# Create a temporary workspace and remove it automatically when the script exits.
INSTALL_TMP=$(mktemp -d)
trap 'rm -rf "$INSTALL_TMP"' EXIT
# Download the requested source branch as a ZIP archive.
curl -fL https://github.com/AryaDesai/DriftCorrect/archive/refs/heads/z-correction.zip -o "$INSTALL_TMP/DriftCorrect.zip"
# Extract the source archive into the temporary workspace.
ditto -xk "$INSTALL_TMP/DriftCorrect.zip" "$INSTALL_TMP"
# Build the macOS application bundle from the extracted source.
bash "$INSTALL_TMP/DriftCorrect-z-correction/DriftCorrect_mac/scripts/bundle_app.sh"
# Create the per-user Applications directory if necessary.
mkdir -p "$HOME/Applications"
# Copy the built application into the user's Applications folder.
ditto "$INSTALL_TMP/DriftCorrect-z-correction/DriftCorrect_mac/build/DriftCorrect.app" "$HOME/Applications/DriftCorrect.app"
echo "Installed. Launch DriftCorrect from your Applications folder."
# Launch the newly installed application.
open "$HOME/Applications/DriftCorrect.app"
