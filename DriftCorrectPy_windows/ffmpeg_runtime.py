"""This module streams gray frames through the bundled FFmpeg into an HEVC or H.264 movie.

The encoder is chosen once for each codec in a process. NVIDIA NVENC is tried first, then Apple VideoToolbox, Intel Quick
Sync and the CPU encoder.
"""

import imageio_ffmpeg
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np


# The movies can use either codec. HEVC is the default because its files are about half the size.
CODECS = ("hevc", "h264")
# The quality runs from 1 to 100. The default of 65 gives the settings that the tools used before the quality could
# be chosen.
DEFAULT_QUALITY = 65


def encoders(codec="hevc", quality=DEFAULT_QUALITY):
    """Return the encoders to try for `codec`, in order, with their FFmpeg options for `quality` from 1 to 100.

    VideoToolbox takes the quality as it is. The other encoders take a constant rate factor from 51 down to 8, where
    a lower factor keeps more detail. The default quality of 65 gives 23, which is the usual default of x264 and x265.
    """
    if codec not in CODECS:
        raise ValueError(f"The codec must be one of {', '.join(CODECS)}")
    if not 1 <= quality <= 100:
        raise ValueError("The quality must be between 1 and 100")
    # The rate factor falls in a straight line as the quality rises, through 23 at the default quality.
    rate = str(min(51, max(0, round(51 - 28 * quality / 65))))
    nvenc, toolbox, quick_sync, cpu = {
        "hevc": ("hevc_nvenc", "hevc_videotoolbox", "hevc_qsv", "libx265"),
        "h264": ("h264_nvenc", "h264_videotoolbox", "h264_qsv", "libx264"),
    }[codec]
    # Each entry names the encoder and gives its options. A GPU encoder is tried before the slower CPU encoder.
    return (
        ("NVIDIA NVENC", ["-c:v", nvenc, "-preset", "p4", "-rc", "vbr", "-cq", rate, "-b:v", "0", "-pix_fmt", "yuv420p"]),
        ("Apple VideoToolbox", ["-c:v", toolbox, "-allow_sw", "1", "-q:v", str(round(quality)), "-pix_fmt", "yuv420p"]),
        ("Intel Quick Sync", ["-c:v", quick_sync, "-preset", "medium", "-global_quality", rate, "-pix_fmt", "nv12"]),
        ("CPU", ["-c:v", cpu, "-crf", rate, "-preset", "medium", "-pix_fmt", "yuv420p"]),
    )


def input_command(width, height, fps):
    return [
        imageio_ffmpeg.get_ffmpeg_exe(),
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "gray",
        "-s", f"{width}x{height}",
        "-r", str(fps), "-i", "-", "-an",
        "-vf", "pad=w='max(ceil(iw/2)*2,64)':h='max(ceil(ih/2)*2,64)'",
    ]

# This holds the name of the encoder chosen for each codec in this process.
_selected = {}

# This folder remembers the encoder that worked last time for each codec, so that later runs test it first.
ENCODER_CACHE = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".cache") / "DriftCorrect"


def candidate_encoders(codec, quality):
    """Return the encoders in the order to test them, with the one that worked last time first. VideoToolbox exists
    only on macOS."""
    found = [e for e in encoders(codec, quality) if sys.platform == "darwin" or e[0] != "Apple VideoToolbox"]
    try:
        last = (ENCODER_CACHE / f"video_encoder_{codec}.txt").read_text(encoding="utf-8").strip()
    except OSError:
        return found
    return sorted(found, key=lambda e: e[0] != last)


def select_encoder(first, fps, codec=CODECS[0], quality=DEFAULT_QUALITY):
    """Return the options of the first encoder that can encode `first`, a gray uint8 frame. The choice is kept for
    each codec in this process.

    The remembered encoder is still tested, so that a changed driver or GPU falls through to the next encoder.
    """
    if codec in _selected:
        return dict(encoders(codec, quality))[_selected[codec]]
    height, width = first.shape[:2]
    failures = []
    for name, options in candidate_encoders(codec, quality):
        command = input_command(width, height, fps) + options + ["-frames:v", "1", "-f", "null", "-"]
        try:
            result = subprocess.run(command, input=first.tobytes(), capture_output=True,
                                    timeout=20, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if result.returncode == 0:
                print(f"Video encoder: {name} ({options[1]})", flush=True)
                _selected[codec] = name
                try:
                    ENCODER_CACHE.mkdir(parents=True, exist_ok=True)
                    (ENCODER_CACHE / f"video_encoder_{codec}.txt").write_text(name, encoding="utf-8")
                except OSError:
                    pass  # The file only saves time. The next run tests the encoders again.
                return options
            detail = result.stderr.decode("utf-8", errors="replace").strip()[-2000:]
        except subprocess.TimeoutExpired:
            detail = "test encode timed out after 20 seconds"
        failures.append(f"{name}: {detail}")
        print(f"Video encoder {name} unavailable. Trying the next encoder. {detail[:300]}", flush=True)
    raise RuntimeError(f"No working {'HEVC' if codec == 'hevc' else 'H.264'} encoder:\n" + "\n".join(failures))


class MovieWriter:
    """Push gray uint8 frames (height, width) to an HEVC or H.264 MP4 through FFmpeg.

    The file is written under a temporary name and renamed on close(), so a
    failed run leaves no partial movie. Frames are padded to even sizes of
    at least 64 × 64, because some encoders reject very small frames.
    """

    def __init__(self, output_path, width, height, fps=2, codec=CODECS[0], quality=DEFAULT_QUALITY):
        if not math.isfinite(fps) or fps <= 0:
            raise ValueError("FPS must be a finite positive number")
        encoders(codec, quality)  # This checks the codec and the quality before any frame arrives.
        self.output_path = Path(output_path)
        self.width, self.height, self.fps = int(width), int(height), fps
        self.codec, self.quality = codec, quality
        self._process = None
        self._errors = None
        self._temporary = None
        self._frames = 0

    def _start(self, first):
        options = select_encoder(first, self.fps, self.codec, self.quality)
        handle, self._temporary = tempfile.mkstemp(prefix=".encoding-", suffix=".mp4", dir=self.output_path.parent)
        os.close(handle)
        command = input_command(self.width, self.height, self.fps) + options + [
            "-tag:v", "hvc1" if self.codec == "hevc" else "avc1", "-movflags", "+faststart", self._temporary]
        self._errors = tempfile.TemporaryFile()
        self._process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=self._errors,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

    def append(self, gray):
        if gray.shape != (self.height, self.width) or gray.dtype != np.uint8:
            raise ValueError("Movie frames must be uint8 arrays of the declared size")
        if self._process is None:
            self._start(gray)
        try:
            self._process.stdin.write(np.ascontiguousarray(gray).tobytes())
        except BrokenPipeError:
            self._fail()
        self._frames += 1

    def _fail(self):
        code = self._process.wait()
        self._errors.seek(0)
        detail = self._errors.read().decode("utf-8", errors="replace")[-8000:]
        self.cancel()
        raise RuntimeError(f"FFmpeg failed (exit {code}):\n{detail}")

    def close(self):
        if self._process is None:
            raise ValueError("Cannot encode a movie with no frames")
        try:
            self._process.stdin.close()
        except BrokenPipeError:
            pass
        if self._process.wait():
            self._fail()
        self._errors.close()
        os.replace(self._temporary, self.output_path)
        self._process = None

    def cancel(self):
        if self._process is not None and self._process.poll() is None:
            self._process.kill()
            self._process.wait()
        self._process = None
        if self._temporary:
            Path(self._temporary).unlink(missing_ok=True)
