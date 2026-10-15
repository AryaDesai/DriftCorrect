"""Multi-level Otsu thresholds (replaces multi_otsu_jax.py).

The dynamic program is the same as before: it maximizes the between-class
variance over contiguous, nonempty histogram classes, and exact ties choose
the earliest split. It now runs in float64 with NumPy. The float32 JAX
version could not tell some near-equal partitions apart; in those cases this
version returns a partition that is at least as good.

Thresholds are histogram BIN EDGES in original intensity units. A pixel
equal to a threshold goes to the brighter class.
"""

import numpy as np

MAX_OTSU_LEVELS = 10
MULTIOTSU_NBINS = 1024


def _solve(histogram, classes):
    """Optimal split indices (first bin of each brighter class) and the score."""
    nb = histogram.shape[0]
    weights = histogram.astype(np.float64) / histogram.sum()
    centers = (np.arange(nb, dtype=np.float64) + 0.5) / nb - 0.5
    mass = np.concatenate(([0.0], np.cumsum(weights)))
    moment = np.concatenate(([0.0], np.cumsum(weights * centers)))

    ends = np.arange(1, nb + 1)[:, None]      # (nb, 1): class ends
    starts = np.arange(nb)[None, :]           # (1, nb): class starts
    interval_mass = mass[ends] - mass[starts]
    interval_moment = moment[ends] - moment[starts]
    positive = interval_mass > 0
    with np.errstate(divide="ignore", invalid="ignore"):
        gain = np.where(positive, interval_moment * interval_moment / np.where(positive, interval_mass, 1.0), 0.0)
    base_valid = (starts < ends) & positive

    previous = np.full(nb + 1, -np.inf)
    previous[0] = 0.0
    parents = []
    for k in range(1, classes + 1):
        valid = base_valid & (starts >= k - 1)
        score = np.where(valid, previous[None, :-1] + gain, -np.inf)
        split = np.argmax(score, axis=1)                  # first maximum = earliest split
        best = score[np.arange(nb), split]
        previous = np.concatenate(([-np.inf], best))
        parents.append(split)

    breaks = [0] * (classes - 1)
    end = nb
    for step in range(classes - 1):
        s = int(parents[classes - step - 1][end - 1])
        breaks[classes - step - 2] = s
        end = s
    return np.asarray(breaks, dtype=np.int64), previous[nb]


def multi_otsu(image, classes=3, nbins=512):
    """Return (thresholds, int32 labels) for one 2-D image.

    Raises ValueError for invalid input, a constant image, or fewer occupied
    histogram bins than classes (as the JAX version did).
    """
    image = np.asarray(image)
    if image.ndim != 2 or image.size == 0:
        raise ValueError("image must be a nonempty 2-D array")
    if classes < 1 or nbins < 1 or classes > nbins:
        raise ValueError("invalid classes or nbins")
    if not np.isfinite(image).all():
        raise ValueError("image must contain only finite intensities")
    if classes == 1:
        return np.empty(0, dtype=np.float64), np.zeros(image.shape, dtype=np.int32)
    if image.min() == image.max():
        raise ValueError("a constant image cannot form multiple nonempty classes")
    histogram, edges = np.histogram(image.astype(np.float64), bins=nbins)
    if np.count_nonzero(histogram) < classes:
        raise ValueError("fewer occupied histogram bins than requested classes")
    breaks, score = _solve(histogram, classes)
    if not np.isfinite(score):
        raise ValueError("no valid partition")
    totals = np.concatenate(([0], np.cumsum(histogram)))
    bounds = np.concatenate(([0], breaks, [nbins]))
    if np.any(np.diff(bounds) <= 0) or np.any(np.diff(totals[bounds]) <= 0):
        raise ValueError("empty class")
    thresholds = edges[breaks]
    labels = np.searchsorted(thresholds, image, side="right").astype(np.int32)
    return thresholds, labels


def multiotsu_thresholds_and_classes(smoothed, levels):
    """Thresholds and class map, with the old fallback for blank frames:
    no thresholds and an all-zero class map."""
    levels = int(np.clip(levels, 2, MAX_OTSU_LEVELS))
    image = np.asarray(smoothed, dtype=np.float32)
    try:
        return multi_otsu(image, classes=levels, nbins=MULTIOTSU_NBINS)
    except ValueError:
        return np.array([], dtype=np.float64), np.zeros(image.shape, dtype=np.int32)


def partition_score(histogram, breaks):
    """Between-class variance of a partition (for tests and diagnostics)."""
    nb = len(histogram)
    w = np.asarray(histogram, dtype=np.float64) / np.sum(histogram)
    c = (np.arange(nb) + 0.5) / nb - 0.5
    b = [0, *list(breaks), nb]
    total = 0.0
    for i in range(len(b) - 1):
        m = w[b[i]:b[i + 1]].sum()
        if m > 0:
            mo = (w[b[i]:b[i + 1]] * c[b[i]:b[i + 1]]).sum()
            total += mo * mo / m
    return total
