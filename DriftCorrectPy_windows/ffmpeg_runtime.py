"""Locate a bundled FFmpeg and stream gray frames to an HEVC movie.

The encoder is chosen once per process: NVIDIA NVENC, Apple VideoToolbox,
Intel Quick Sync, then the CPU (libx265).
"""

import imageio_ffmpeg
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import numpy as np


ENCODERS = (
    ("NVIDIA NVENC", ["-c:v", "hevc_nvenc", "-preset", "p4", "-rc", "vbr", "-cq", "23", "-b:v", "0", "-pix_fmt", "yuv420p"]),
    ("Apple VideoToolbox", [
    "-c:v", "hevc_videotoolbox",
    "-allow_sw", "1",
    "-q:v", "65",
    "-pix_fmt", "yuv420p",
]),
    ("Intel Quick Sync", ["-c:v", "hevc_qsv", "-preset", "medium", "-global_quality", "23", "-pix_fmt", "nv12"]),
    ("CPU", ["-c:v", "libx265", "-crf", "23", "-preset", "medium", "-pix_fmt", "yuv420p"]),

)


def input_command(width, height, fps, pix_fmt="gray"):
    return [
        imageio_ffmpeg.get_ffmpeg_exe(),
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", pix_fmt,
        "-s", f"{width}x{height}",
        "-r", str(fps), "-i", "-", "-an",
        "-vf", "pad=w='max(ceil(iw/2)*2,64)':h='max(ceil(ih/2)*2,64)'",
    ]

_selected = None

# Name of the encoder that worked last time, so later runs test it first.
ENCODER_CACHE = Path(os.environ.get("LOCALAPPDATA") or Path.home() / ".cache") / "DriftCorrect" / "video_encoder.txt"


def candidate_encoders():
    """ENCODERS in test order: last run's encoder first. VideoToolbox exists only on macOS."""
    encoders = [e for e in ENCODERS if sys.platform == "darwin" or e[0] != "Apple VideoToolbox"]
    try:
        last = ENCODER_CACHE.read_text(encoding="utf-8").strip()
    except OSError:
        return encoders
    return sorted(encoders, key=lambda e: e[0] != last)


def select_encoder(first, fps):
    """First encoder that can encode `first` (a gray uint8 frame). Cached per process.

    The remembered encoder is still test-encoded, so a changed driver or GPU
    falls through to the next encoder exactly as before.
    """
    global _selected
    if _selected is not None:
        return _selected
    height, width = first.shape[:2]
    failures = []
    for name, options in candidate_encoders():
        command = input_command(width, height, fps) + options + ["-frames:v", "1", "-f", "null", "-"]
        try:
            result = subprocess.run(command, input=first.tobytes(), capture_output=True,
                                    timeout=20, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if result.returncode == 0:
                print(f"Video encoder: {name} ({options[1]})", flush=True)
                _selected = options
                try:
                    ENCODER_CACHE.parent.mkdir(parents=True, exist_ok=True)
                    ENCODER_CACHE.write_text(name, encoding="utf-8")
                except OSError:
                    pass  # only a speed-up; the next run probes again
                return options
            detail = result.stderr.decode("utf-8", errors="replace").strip()[-2000:]
        except subprocess.TimeoutExpired:
            detail = "test encode timed out after 20 seconds"
        failures.append(f"{name}: {detail}")
        print(f"Video encoder {name} unavailable; trying next encoder. {detail[:300]}", flush=True)
    raise RuntimeError("No working HEVC encoder:\n" + "\n".join(failures))


# Windows keeps the .exe suffix; macOS and Linux do not.
FFMPEG_NAME = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"




class MovieWriter:
    """Push gray uint8 frames (height, width) to an HEVC MP4 through FFmpeg.

    The file is written under a temporary name and renamed on close(), so a
    failed run leaves no partial movie. Frames are padded to even sizes of
    at least 64 × 64, because some encoders reject very small frames.
    """

    def __init__(self, output_path, width, height, fps=2):
        if not math.isfinite(fps) or fps <= 0:
            raise ValueError("FPS must be a finite positive number")
        self.output_path = Path(output_path)
        self.width, self.height, self.fps = int(width), int(height), fps
        self._process = None
        self._errors = None
        self._temporary = None
        self._frames = 0

    def _start(self, first):
        options = select_encoder(first, self.fps)
        handle, self._temporary = tempfile.mkstemp(prefix=".encoding-", suffix=".mp4", dir=self.output_path.parent)
        os.close(handle)
        command = input_command(self.width, self.height, self.fps) + options + [
            "-tag:v", "hvc1", "-movflags", "+faststart", self._temporary]
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


def encode_gray_mp4(frames, output_path, fps=2):
    """Encode an iterable of gray uint8 frames."""
    writer = None
    try:
        for frame in frames:
            if writer is None:
                writer = MovieWriter(output_path, frame.shape[1], frame.shape[0], fps)
            writer.append(frame)
        if writer is None:
            raise ValueError("Cannot encode a movie with no frames")
        writer.close()
    except BaseException:
        if writer is not None:
            writer.cancel()
        raise
