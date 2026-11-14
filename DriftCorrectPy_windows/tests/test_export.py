"""Tests of the Export tool on the synthetic embryo of test_alignment.py."""

import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import export_movies
import ffmpeg_runtime
from test_alignment import SLICES, SIZE, write_movie
from useful_functions import FrameSource, auto_contrast


class RecordedMovie:
    """A movie writer that keeps the frames in memory."""

    made = []

    def __init__(self, path, width, height, fps=2, codec="hevc", quality=65):
        self.path, self.width, self.height, self.frames, self.closed = Path(path), width, height, [], False
        RecordedMovie.made.append(self)

    def append(self, gray):
        self.frames.append(gray.copy())

    def close(self):
        self.closed = True

    def cancel(self):
        pass


def export(monkeypatch, *argv):
    RecordedMovie.made = []
    monkeypatch.setattr(export_movies, "MovieWriter", RecordedMovie)
    export_movies.export(export_movies.parse_args([*map(str, argv), "--cpu"]))
    return RecordedMovie.made


def test_export_shows_slice_and_compares_side_by_side(tmp_path, monkeypatch):
    still_dir, moved_dir = tmp_path / "still", tmp_path / "moved"
    still_dir.mkdir()
    moved_dir.mkdir()
    still = write_movie(still_dir, [0, 0, 0, 0], [(0, 0)] * 4).parent / "P0_concat.ome.tif"
    moved = write_movie(moved_dir, [0, 1, 2], [(0, 0)] * 3).parent / "P0_concat.ome.tif"

    # A movie of one slice with the brightness of each frame matches the slice scaled on its own.
    made = export(monkeypatch, moved, "--slice", 7, "--contrast", "frame")
    assert [m.path.name for m in made] == ["P0_concat_nuc_z7.mp4"]
    source = FrameSource(moved)
    for t in range(3):
        assert np.array_equal(made[0].frames[t], auto_contrast(source.read_frame(t)[0, 6].astype(np.float32)))
    source.close()

    # With the brightness of the whole movie, a scene that does not change gives the same frame every time.
    made = export(monkeypatch, still)
    assert len(made[0].frames) == 4 and made[0].closed
    assert all(np.array_equal(f, made[0].frames[0]) for f in made[0].frames)

    # The second movie sits to the right, and the export stops after the shorter movie. Timepoint 0 of both movies
    # is the same stack, so with the brightness of each frame the two halves of the first frame are equal.
    made = export(monkeypatch, still, "--compare", moved, "--contrast", "frame")
    side = made[0]
    assert (side.width, side.height, len(side.frames)) == (2 * SIZE, SIZE, 3)
    assert np.array_equal(side.frames[0][:, :SIZE], side.frames[0][:, SIZE:])

    # A slice outside the stack is refused.
    with pytest.raises(ValueError):
        export(monkeypatch, still, "--slice", SLICES + 1)


@pytest.mark.parametrize("codec, name", [("hevc", "hevc"), ("h264", "h264")])
def test_movie_writer_codecs(tmp_path, codec, name):
    path = tmp_path / f"{codec}.mp4"
    writer = ffmpeg_runtime.MovieWriter(path, 257, 191, 2, codec, 40)
    for t in range(6):
        writer.append(((np.arange(257 * 191) + 13 * t) % 256).astype(np.uint8).reshape(191, 257))
    writer.close()
    probe = subprocess.run([ffmpeg_runtime.imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-i", str(path)],
                           capture_output=True, text=True)
    assert f"Video: {name}" in probe.stderr
