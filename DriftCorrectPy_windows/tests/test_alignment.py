"""Tests of the image matching, the anchor and the z correction on a synthetic embryo.

The embryo is a fixed scene of blobs that look like nuclei inside a bright disc. Each timepoint shows a stack
that starts at a different depth of that scene, moved in xy.
"""

import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
import tifffile
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import centroid_align_xy
import image_match
import z_drift
from useful_functions import save_ome_tiff

SIZE, DEPTH, SLICES, BASE = 160, 44, 14, 14


def make_scene():
    rng = np.random.default_rng(7)
    y, x = np.mgrid[0:SIZE, 0:SIZE]
    disc = np.hypot(y - SIZE / 2, x - SIZE / 2) < 62
    scene = np.where(disc, 500.0, 150.0)[None].repeat(DEPTH, axis=0) + rng.random((DEPTH, SIZE, SIZE)) * 30
    for _ in range(260):
        angle, radius = rng.random() * 2 * np.pi, 56 * np.sqrt(rng.random())
        cy, cx = SIZE / 2 + radius * np.sin(angle), SIZE / 2 + radius * np.cos(angle)
        cz, amp = 1 + rng.random() * (DEPTH - 2), 1500 + 2000 * rng.random()
        z, yy, xx = np.mgrid[0:DEPTH, 0:SIZE, 0:SIZE]
        scene += amp * np.exp(-0.5 * (((z - cz) / 0.9) ** 2 + ((yy - cy) / 3.2) ** 2 + ((xx - cx) / 3.2) ** 2))
    return np.clip(scene, 0, 65535).astype(np.uint16)


SCENE = make_scene()


def frame(offset, dy=0, dx=0):
    """One (1, Z, Y, X) timepoint whose first slice is scene plane BASE + offset. The scene is moved by (dy, dx)
    pixels, and pixels that the move uncovers are 0."""
    out = np.zeros((1, SLICES, SIZE, SIZE), np.uint16)
    planes = SCENE[BASE + offset:BASE + offset + SLICES]
    out[0, :, max(0, dy):SIZE + min(0, dy), max(0, dx):SIZE + min(0, dx)] = \
        planes[:, max(0, -dy):SIZE + min(0, -dy), max(0, -dx):SIZE + min(0, -dx)]
    return out


def write_movie(folder, offsets, moves):
    tif = folder / "P0_concat.ome.tif"
    data = np.stack([frame(o, *m) for o, m in zip(offsets, moves)])
    save_ome_tiff(tif, data, ["nuc"], SimpleNamespace(x=0.43, y=0.43, z=2.0), 240)
    yaml = folder / "P0_nuc_threshold.yaml"
    yaml.write_text(f"parameters:\n  channel: nuc\n  channel_index: 0\n  sigma: 8\n  percentile: 60.0\nsource:\n  file: {tif}\n")
    return yaml


def run(yaml, *flags):
    tif = yaml.parent / "P0_concat.ome.tif"
    args = centroid_align_xy.parse_args([str(tif), "--yaml", str(yaml), "--no_movies", "--cpu", *flags])
    written, shifts = centroid_align_xy.align(args)
    # tifffile drops the channel axis of a file with one channel, so it is put back.
    out = tifffile.imread(written[0])
    return out.reshape(out.shape[0], 1, *out.shape[-3:]), shifts


def test_match_finds_large_jumps():
    a = image_match.prepare(frame(0)[0, 6])
    for dy, dx in ((0, 0), (3, -2), (-17, 25), (38, -41)):
        for maximum_angle in (0.0, 3.0):
            step, cost = image_match.match(a, image_match.prepare(frame(0, dy, dx)[0, 6]), maximum_angle=maximum_angle)
            # The shift is placed between pixels, so a move by whole pixels is found to within a small part of one.
            assert np.allclose(step, image_match.shift(-dx, -dy), atol=0.01)
            assert cost < 0.1


def test_match_finds_rotation():
    first = frame(0)[0, 6].astype(np.float32)
    a = image_match.prepare(first)
    mid = (SIZE - 1) / 2
    for degrees, dx, dy in ((2.0, 5.0, -4.0), (-1.5, -12.0, 9.0)):
        # Turn and shift the scene, and check that the match undoes both.
        move = image_match.shift(dx, dy) @ image_match.rotation(degrees, mid, mid)
        back = np.linalg.inv(move)
        moved = ndimage.affine_transform(first, [[back[1, 1], back[1, 0]], [back[0, 1], back[0, 0]]],
                                         offset=(back[1, 2], back[0, 2]), order=1)
        step, cost = image_match.match(a, image_match.prepare(moved), maximum_angle=3)
        assert abs(image_match.angle_of(step) + degrees) <= 0.2
        for point in ((mid, mid), (mid + 50, mid), (mid, mid - 50)):
            assert np.allclose(image_match.apply(step @ move, *point), point, atol=1.5)
        assert cost < 0.15


def test_anchor_holds_the_body():
    # The cells move through the body by 1 pixel and turn by half a degree at every step, and at timepoint 10 the
    # stage jumps by 20 pixels. The body itself does not move or turn apart from that jump.
    T, w, h = 30, 200, 100
    steps, poses = [], []
    for t in range(T):
        jump = 20.0 if t >= 10 else 0.0
        steps.append(image_match.shift(-21 if t == 10 else -1, 0) @ image_match.rotation(0.5, 80 + jump, 40))
        poses.append((80 + jump, 40.0))
    held = image_match.place(steps, poses, 2, w, h)
    free = image_match.place(steps, None, 2, w, h)
    for t in range(6, 24):
        # With the anchor the body stays in the middle and keeps its direction.
        assert np.allclose(image_match.apply(held[t], poses[t][0], poses[t][1]), ((w - 1) / 2, (h - 1) / 2), atol=0.5)
        assert abs(image_match.angle_of(held[t])) <= 0.2
    # Without it the sum of the steps carries the body away.
    assert abs(image_match.apply(free[-1], 100, 40)[0] - 100) > 20


def test_positions_use_comparisons_further_back():
    # The tissue sinks by a fifth of a slice at every step. Neighbours measure no movement, and the comparison
    # five timepoints back measures one slice.
    T = 41
    edges = [(t - 1, t, 0.0) for t in range(1, T)]
    assert abs(z_drift.positions(T, edges)[-1]) < 1e-6
    z = z_drift.positions(T, edges + [(t - 5, t, -1.0) for t in range(5, T)])
    assert z[-1] < -0.15 * (T - 1) and z[0] == 0
    assert np.allclose(z_drift.positions(4, [(0, 1, 2.0), (1, 2, -0.5), (2, 3, 1.0)]), [0, 2, 1.5, 2.5])


def test_plan_and_place():
    steps = [z_drift.Step(dz=d) for d in (0, 0.55, 0.2, 2.0, -3.4)]
    plan = z_drift.plan(steps)
    assert list(plan.shift) == [0, 0, -1, -3, 1] and (plan.pad_low, plan.pad_high) == (3, 1)
    moved = z_drift.place(frame(0), 2, 1, 3)
    assert moved.shape[1] == SLICES + 4 and np.array_equal(moved[0, 3], frame(0)[0, 0]) and not moved[0, :3].any()


def same_scene(first, plane):
    """Return the number of pixels that hold data in both planes, and how much the two planes differ there as a
    share of their brightness. The output is interpolated, so the values agree closely without being equal."""
    both = (first > 0) & (plane > 0)
    a, b = first[both].astype(float), plane[both].astype(float)
    return both.sum(), np.abs(a - b).sum() / a.sum()


def test_image_matching_with_z_correction(tmp_path):
    offsets = [0, 2, 2, -1]
    moves = [(0, 0), (6, -5), (-8, 11), (-7, 12)]
    yaml = write_movie(tmp_path, offsets, moves)
    for region in (["--xy_region", "whole"], ["--xy_region", "mask"], ["--xy_region", "box", "--xy_box", "40", "40", "80", "80"]):
        out, shifts = run(yaml, "--xy_no_hold", "--z_correct", *region)
        # Every timepoint moves back onto the first one, in xy and in z.
        # The stacks start at different depths, so their projections differ slightly and the shift is found to
        # within a few hundredths of a pixel.
        assert np.allclose(shifts[0], [(-dy, -dx) for dy, dx in moves], atol=0.05)
        # The last timepoint moves down by one slice, so one empty slice is added below and scene plane 6 of the
        # first timepoint is in output slice 7.
        k = 7
        for t in range(1, len(offsets)):
            compared, difference = same_scene(out[0, 0, k], out[t, 0, k])
            assert compared > 10_000 and difference < 0.02


def test_image_matching_holds_the_body(tmp_path):
    # The scene and its mask move together, so holding the body must put the scene in the same place at every
    # timepoint.
    moves = [(0, 0), (4, -3), (9, 2), (-12, 15), (-10, 14), (3, 3)]
    out, _ = run(write_movie(tmp_path, [0] * 6, moves))
    first = out[0, 0, 6].astype(float)
    for t in range(1, len(moves)):
        plane = out[t, 0, 6].astype(float)
        both = (first > 0) & (plane > 0)
        assert np.abs(plane[both] - first[both]).sum() / first[both].sum() < 0.05


def test_z_correction_without_xy(tmp_path):
    offsets = [0, 1, 3, 3]
    out, _ = run(write_movie(tmp_path, offsets, [(0, 0)] * 4), "--xy_method", "none", "--z_correct")
    table = np.genfromtxt(tmp_path / "aligned_P0_concat" / "P0_concat_z_shifts.csv", delimiter=",", names=True)
    assert list(table["shift_slices"]) == offsets
    assert out.shape[2] == SLICES + 3
    # Without the xy alignment the pixel values do not change, so scene plane 6 of the first timepoint is the same
    # output slice at every timepoint.
    k = 6 + 3
    for t in range(1, len(offsets)):
        assert np.array_equal(out[t, 0, k], out[0, 0, k])


def test_drop_compares_with_the_last_kept_timepoint(tmp_path):
    def kept(offsets):
        tracker = z_drift.Tracker(maximum_step=2)
        for o in offsets:
            tracker.add(lambda m, o=o: z_drift.describe(frame(o), 0, None, m))
        return tracker.plan()

    # One timepoint that jumps and comes back is dropped, and the timepoint after it is kept.
    spike = kept([0, 0, 4, 0, 1])
    assert list(spike.kept) == [0, 1, 3, 4]
    assert spike.pad_low + spike.pad_high == 1
    # A jump that stays drops only its first timepoint.
    jump = kept([0, 0, 4, 4, 5])
    assert list(jump.kept) == [0, 1, 3, 4]
    assert jump.pad_low + jump.pad_high == 5
    # The xy matching also skips the dropped timepoint.
    offsets, moves = [0, 0, 4, 0, 1], [(0, 0), (2, -1), (9, 7), (3, -2), (4, -2)]
    out, _ = run(write_movie(tmp_path, offsets, moves), "--xy_no_hold", "--xy_no_rotation", "--z_correct",
                 "--z_drop_above", "2")
    assert out.shape[0] == 4

