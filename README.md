# DriftCorrect

Convert microscopy movies, create embryo masks, and correct XY and Z drift.

## Windows

Paste into **Anaconda Prompt**:

```bat
curl -fL -o install_windows.bat https://raw.githubusercontent.com/AryaDesai/DriftCorrect/z-correction/install_windows.bat
install_windows.bat
```

The script downloads the project, installs uv and the Python dependencies in a
private environment, and creates a desktop shortcut. Launch with that shortcut
or type `driftcorrect` in the same prompt. FFmpeg is included.

No administrator access should be needed. uv, Python dependencie and the app are
installed under `%LOCALAPPDATA%\DriftCorrect`. Dependencies are defined in
`pyproject.toml` and pinned in `uv.lock`. We use `uv sync --locked` for setup

Setup process detects the driver's CUDA support,
installs the matching locked CuPy and CUDA runtime dependencies and runs a
GPU calculation as a check. It tries CUDA 12 if CUDA 13 does not work, and uses CPU mode
when no supported GPU is available. An existing NVIDIA driver is required, this should be included with most computers with an NVIDIA GPU.

## Mac

Paste into **Terminal** on an Apple silicon Mac running macOS 14 or later:

```bash
curl -fL -o install_mac.sh https://raw.githubusercontent.com/AryaDesai/DriftCorrect/z-correction/install_mac.sh
bash install_mac.sh
```

The script installs Apple's command-line tools if needed, downloads the project,
builds the app, and opens it. If Apple's installation dialog appears, you can complete it/click yes/whatever and the script continues automatically. The app is installed in `~/Applications`.

Run the same commands again to update either version.

See the [Mac guide](DriftCorrect_mac/README.md) and
[Windows guide](DriftCorrectPy_windows/README.md) for usage details.
