"""find_threshold.py — interactive threshold tuning for embryo masking (the Mask tool).

Load an ND2 or TIFF file, pick a channel and tune sigma, method and
percentile while the mask overlay and centroid crosshair update. Save writes
one YAML per embryo in the schema that centroid_align_xy.py reads.

Frames are read on demand: the Z max projection of each (t, position) is kept
in a small cache, and the next timepoint is read ahead in the background.
Smoothing uses the same backend as the alignment (CUDA when available), so
the mask on screen is the mask the alignment finds.

Usage:
    python find_threshold.py
"""

import datetime
import sys
import threading
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import yaml
from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg
from matplotlib.figure import Figure
from PyQt6.QtCore import QEventLoop, Qt, QTimer
from PyQt6.QtGui import QImage, QPixmap
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QFrame, QHBoxLayout, QLabel, QLineEdit,
    QMessageBox, QPushButton, QSizePolicy, QSlider, QSpinBox, QSplitter, QVBoxLayout, QWidget,
)

from backend import get_backend
from common_gui import Relay, run_in_background
from multi_otsu import MAX_OTSU_LEVELS, multiotsu_thresholds_and_classes
from useful_functions import (
    LEVEL_COLORS, FrameSource, find_largest_mask_xy, physical_memory, render_composite, roi_otsu_threshold,
    stem_without_ome,
)

METHODS = {"Percentile": "percentile", "Multi-Level Otsu": "multiotsu", "Percentile -> Otsu ROI": "percentile_otsu_roi"}


# ── Data access ──────────────────────────────────────────────────────────────


class ProjectionSource:
    """(t, p) → float32 (C, Y, X) Z max projection, with an LRU cache and read-ahead."""

    def __init__(self, path, backend):
        self.source = FrameSource(path)
        s = self.source
        self.T, self.P, self.C, self.Y, self.X = s.T, s.P, s.C, s.Y, s.X
        self.is_nd2 = s.is_nd2
        self.channel_names = list(s.channel_names[:s.C])
        self._backend = backend
        # Keep up to 1/16 of RAM of projections, at least 2 and at most 64 entries.
        entry = max(1, self.C * self.Y * self.X * 4)
        self._capacity = int(np.clip(physical_memory() // 16 // entry, 2, 64))
        self._cache = OrderedDict()
        self._pending = {}
        self._lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=1)

    def _load(self, key):
        return self._backend.max_project_all(self.source.read_frame(*key))

    def _store(self, key, value):
        with self._lock:
            self._cache[key] = value
            self._cache.move_to_end(key)
            while len(self._cache) > self._capacity:
                self._cache.popitem(last=False)

    def get(self, t, p):
        key = (t, p)
        with self._lock:
            if key in self._cache:
                self._cache.move_to_end(key)
                return self._cache[key]
            future = self._pending.pop(key, None)
        value = future.result() if future is not None else self._load(key)
        self._store(key, value)
        return value

    def prefetch(self, t, p):
        key = (t, p)
        with self._lock:
            if key in self._cache or key in self._pending:
                return
            self._pending = {k: f for k, f in self._pending.items() if not f.done() or k == key}
            self._pending[key] = self._pool.submit(self._load, key)

    def close(self):
        self._pool.shutdown(wait=True, cancel_futures=True)
        self.source.close()


# ── Widgets ──────────────────────────────────────────────────────────────────


class EmbryoLabel(QLabel):
    """Keeps the image proportional when the window or the divider changes size."""

    def __init__(self):
        super().__init__()
        self._image = QPixmap()
        self.setMinimumSize(100, 100)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)

    def setPixmap(self, pixmap):
        self._image = pixmap
        self._resize_image()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._resize_image()

    def _resize_image(self):
        if not self._image.isNull():
            super().setPixmap(self._image.scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio,
                                                 Qt.TransformationMode.SmoothTransformation))


# ── Application ──────────────────────────────────────────────────────────────


class ThresholdApp(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Find threshold for masking PSM")
        self.backend = None        # set in the background by _backend_ready
        self.data = None
        self._generation = 0       # bumped per loaded file; part of every cache key
        self.file_path = None
        self.T = self.P = self.C = self.Y = self.X = 0
        self.embryo_idx = 0
        self.custom_timepoint_params = {}
        self.level_vars = []
        # Caches below are touched only by the worker thread (_pool).
        self._smooth_key = self._smoothed = self._edges = None
        self._class_key = None
        self._class_map = None
        self._class_thresholds = np.array([])
        self._class_counts = None
        # Redraws run on one worker thread; only the newest request is computed and shown.
        self._pool = ThreadPoolExecutor(max_workers=1)
        self._request = 0
        self._relay = Relay(self)
        self._relay.done.connect(self._show)
        self.playing = False
        self.animation_timer = QTimer(self)
        self.animation_timer.setSingleShot(True)
        self.animation_timer.timeout.connect(self._animate)
        self._build_ui()
        screen = self.screen().availableGeometry()
        self.resize(min(960, int(screen.width() * 0.9)), min(1200, int(screen.height() * 0.9)))
        # CUDA start-up takes seconds; show the window first.
        run_in_background(get_backend, self._backend_ready, self)

    def _backend_ready(self, backend):
        self.backend = backend
        self.backend_label.setText(f"Compute: {backend.name}")
        self.browse_btn.setEnabled(True)
        self.load_btn.setEnabled(True)

    # ── UI construction ──────────────────────────────────────────────────

    def _build_ui(self):
        layout = QHBoxLayout(self)
        ctrl = QVBoxLayout()
        controls = QWidget()
        controls.setLayout(ctrl)
        controls.setMaximumWidth(340)
        layout.addWidget(controls)
        title = QLabel("Find threshold for masking PSM")
        title.setStyleSheet("font: bold 14pt;")
        ctrl.addWidget(title)
        legend = QLabel("Red overlay = mask  |  + = centroid")
        legend.setStyleSheet("color: gray;")
        ctrl.addWidget(legend)
        self.backend_label = QLabel("Compute: detecting…")
        self.backend_label.setStyleSheet("color: gray;")
        ctrl.addWidget(self.backend_label)

        self.browse_btn = self._add_button(ctrl, "Browse", self._browse)
        self.path_entry = QLineEdit()
        self.path_entry.returnPressed.connect(self._load_file)
        ctrl.addWidget(self.path_entry)
        self.load_btn = self._add_button(ctrl, "Load", self._load_file)
        self.browse_btn.setEnabled(False)
        self.load_btn.setEnabled(False)
        ctrl.addWidget(QLabel("Channel"))
        self.channel_combo = QComboBox()
        ctrl.addWidget(self.channel_combo)
        self.channel_combo.activated.connect(lambda _: self._update())

        self.nav_frame = QWidget()
        nav = QHBoxLayout(self.nav_frame)
        nav.setContentsMargins(0, 0, 0, 0)
        ctrl.addWidget(self.nav_frame)
        self._add_button(nav, "Prev", lambda: self._step_embryo(-1))
        self.embryo_label = QLabel("Embryo 0 / 0")
        nav.addWidget(self.embryo_label)
        self._add_button(nav, "Next", lambda: self._step_embryo(1))

        self.t_slider = self._add_slider(ctrl, "T", 0, 0, 0)
        self.sigma_slider = self._add_slider(ctrl, "Sigma", 1, 100, 2)
        ctrl.addWidget(QLabel("Threshold Method"))
        self.method_combo = QComboBox()
        self.method_combo.addItems(list(METHODS))
        ctrl.addWidget(self.method_combo)
        self.method_combo.activated.connect(lambda _: self._on_method_change())

        self.levels_frame = QWidget()
        levels_layout = QHBoxLayout(self.levels_frame)
        levels_layout.setContentsMargins(0, 0, 0, 0)
        levels_layout.addWidget(QLabel("Levels"))
        self.levels_spin = QSpinBox()
        self.levels_spin.setRange(2, MAX_OTSU_LEVELS)
        self.levels_spin.setValue(3)
        levels_layout.addWidget(self.levels_spin)
        self.levels_spin.valueChanged.connect(lambda _: self._on_levels_change())
        ctrl.addWidget(self.levels_frame)
        self.levels_frame.hide()

        self.levels_check_frame = QWidget()
        self.levels_check_layout = QHBoxLayout(self.levels_check_frame)
        self.levels_check_layout.setContentsMargins(0, 0, 0, 0)
        ctrl.addWidget(self.levels_check_frame)
        self.levels_check_frame.hide()

        # Percentile is stored in half-percent steps because Qt sliders use integers.
        self.pct_slider = self._add_slider(ctrl, "Percentile", 20, 199, 180, 0.5)
        self.invert_check = QCheckBox("Invert Mask")
        ctrl.addWidget(self.invert_check)
        self.invert_check.toggled.connect(lambda _: self._update())

        self._add_separator(ctrl)
        self._add_button(ctrl, "Apply to current T", self._apply_to_current_t)
        range_layout = QHBoxLayout()
        ctrl.addLayout(range_layout)
        range_layout.addWidget(QLabel("Range"))
        self.range_start_spin = QSpinBox()
        self.range_end_spin = QSpinBox()
        for spin in (self.range_start_spin, self.range_end_spin):
            spin.setRange(0, 0)
            range_layout.addWidget(spin)
        self._add_button(range_layout, "Apply", self._apply_to_range)
        self.override_status_label = QLabel("Customized: 0 / 0 T")
        self.override_status_label.setStyleSheet("color: gray;")
        ctrl.addWidget(self.override_status_label)

        self._add_separator(ctrl)
        anim = QHBoxLayout()
        ctrl.addLayout(anim)
        self.play_btn = self._add_button(anim, "Play", self._toggle_play)
        anim.addWidget(QLabel("Delay (s):"))
        self.delay_spin = QDoubleSpinBox()
        self.delay_spin.setRange(0.1, 5.0)
        self.delay_spin.setSingleStep(0.1)
        self.delay_spin.setDecimals(1)
        self.delay_spin.setValue(0.5)
        anim.addWidget(self.delay_spin)

        self._add_separator(ctrl)
        self._add_button(ctrl, "Save thresholds to YAML", self._save_yaml)
        self.status_label = QLabel()
        self.status_label.setStyleSheet("color: green;")
        self.status_label.setWordWrap(True)
        ctrl.addWidget(self.status_label)
        ctrl.addStretch()

        display_frame = QWidget()
        display = QVBoxLayout(display_frame)
        layout.addWidget(display_frame, 1)
        self.display_splitter = QSplitter(Qt.Orientation.Vertical)
        self.display_splitter.setChildrenCollapsible(False)
        display.addWidget(self.display_splitter)
        image_panel = QWidget()
        image_layout = QVBoxLayout(image_panel)
        image_layout.setContentsMargins(0, 0, 0, 0)
        self.display_splitter.addWidget(image_panel)
        self.header_label = QLabel()
        self.header_label.setWordWrap(True)
        self.header_label.setStyleSheet("font: 12pt;")
        image_layout.addWidget(self.header_label)
        self.img_label = EmbryoLabel()
        image_layout.addWidget(self.img_label, 1)
        self.cap_label = QLabel()
        self.cap_label.setWordWrap(True)
        self.cap_label.setStyleSheet("color: gray;")
        image_layout.addWidget(self.cap_label)

        histogram_panel = QWidget()
        histogram_layout = QVBoxLayout(histogram_panel)
        histogram_layout.setContentsMargins(0, 0, 0, 0)
        histogram_layout.addWidget(QLabel("Gaussian-smoothed intensity histogram"))
        self.hist_figure = Figure(figsize=(5, 5), layout="constrained")
        self.hist_canvas = FigureCanvasQTAgg(self.hist_figure)
        self.hist_canvas.setMinimumHeight(130)
        self.hist_ax = self.hist_figure.add_subplot(111)
        self.hist_ax.set_box_aspect(1)
        self.hist_ax.set_axis_off()
        self.hist_ax.text(0.5, 0.5, "Load a file to display its histogram", ha="center", va="center",
                          transform=self.hist_ax.transAxes)
        histogram_layout.addWidget(self.hist_canvas, 1)
        self.hist_note = QLabel()
        self.hist_note.setWordWrap(True)
        histogram_layout.addWidget(self.hist_note)
        self.display_splitter.addWidget(histogram_panel)
        self.display_splitter.setStretchFactor(0, 1)
        self.display_splitter.setStretchFactor(1, 1)
        QTimer.singleShot(0, lambda: self.display_splitter.setSizes([self.display_splitter.height() // 2] * 2))

    def _add_button(self, layout, text, callback):
        button = QPushButton(text)
        button.clicked.connect(lambda _: callback())
        layout.addWidget(button)
        return button

    def _add_separator(self, layout):
        separator = QFrame()
        separator.setFrameShape(QFrame.Shape.HLine)
        layout.addWidget(separator)

    def _add_slider(self, layout, title, minimum, maximum, value, scale=1):
        label = QLabel(f"{title}: {value * scale}")
        layout.addWidget(label)
        slider = QSlider(Qt.Orientation.Horizontal)
        slider.setRange(minimum, maximum)
        slider.setValue(value)
        # No tracking: valueChanged (and the recompute) fires on release, while the label follows the drag.
        slider.setTracking(False)
        slider.sliderMoved.connect(lambda v: label.setText(f"{title}: {v * scale}"))
        slider.valueChanged.connect(lambda v: label.setText(f"{title}: {v * scale}"))
        slider.valueChanged.connect(lambda _: self._update())
        layout.addWidget(slider)
        return slider

    # ── Loading ──────────────────────────────────────────────────────────

    def _browse(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select ND2 or TIF file", "",
                                              "ND2 or TIFF (*.nd2 *.tif *.tiff);;All files (*)")
        if path:
            self.path_entry.setText(path)
            self._load_file()

    def _load_file(self):
        path = self.path_entry.text().strip()
        if not path or self.backend is None:
            return
        if not Path(path).is_file():
            QMessageBox.critical(self, "Error", f"File not found:\n{path}")
            return
        self._stop_play()
        self.status_label.setText("Loading...")
        QApplication.processEvents(QEventLoop.ProcessEventsFlag.ExcludeUserInputEvents)
        try:
            data = ProjectionSource(path, self.backend)
        except Exception as e:
            self.status_label.setText("")
            QMessageBox.critical(self, "Cannot open file", f"{path}\n\n{e}")
            return
        if self.data is not None:
            self._pool.submit(self.data.close)  # after any queued work on the old file
        self.data = data
        self._generation += 1
        self.file_path = path
        self.T, self.P, self.C, self.Y, self.X = data.T, data.P, data.C, data.Y, data.X
        self.custom_timepoint_params = {}
        self.embryo_idx = 0

        self.channel_combo.clear()
        self.channel_combo.addItems(data.channel_names)
        self.channel_combo.setCurrentIndex(0)
        for w in (self.range_start_spin, self.range_end_spin, self.t_slider):
            w.setMaximum(max(0, self.T - 1))
            w.setValue(0)
        self.nav_frame.setVisible(self.P > 1)
        self._update_embryo_label()
        self.status_label.setText(f"Loaded: T={self.T}, P={self.P}, C={self.C}, Y={self.Y}, X={self.X}")
        self._update_override_status()
        self._update()

    # ── Embryo navigation ────────────────────────────────────────────────

    def _step_embryo(self, step):
        if self.P <= 1:
            return
        self.embryo_idx = (self.embryo_idx + step) % self.P
        self._update_embryo_label()
        self._update()

    def _update_embryo_label(self):
        self.embryo_label.setText(f"Embryo {self.embryo_idx} / {self.P - 1}")

    # ── Parameters ───────────────────────────────────────────────────────

    def _on_method_change(self):
        multi = self._method_code() == "multiotsu"
        self.pct_slider.setEnabled(not multi)
        self.levels_frame.setVisible(multi)
        self.levels_check_frame.setVisible(multi)
        if multi and not self.level_vars:
            self._rebuild_level_checkboxes()
        self._update()

    def _rebuild_level_checkboxes(self):
        """One checkbox per class. The selection resets to the brightest class,
        because class i of n and class i of n+1 cover different intensities."""
        while self.levels_check_layout.count():
            widget = self.levels_check_layout.takeAt(0).widget()
            widget.setParent(None)
            widget.deleteLater()
        self.level_vars = []
        levels = self.levels_spin.value()
        for i in range(levels):
            checkbox = QCheckBox(str(i))
            checkbox.setChecked(i == levels - 1)
            checkbox.toggled.connect(lambda _: self._update())
            self.level_vars.append(checkbox)
            self.levels_check_layout.addWidget(checkbox)

    def _on_levels_change(self):
        self._rebuild_level_checkboxes()
        self._update()

    def _selected_levels(self):
        return [i for i, var in enumerate(self.level_vars) if var.isChecked()]

    def _method_code(self):
        return METHODS.get(self.method_combo.currentText(), "percentile")

    def _channel_index(self):
        return max(0, self.channel_combo.currentIndex())

    def _current_params(self):
        ch_idx = self._channel_index()
        method = self._method_code()
        names = self.data.channel_names if self.data else []
        params = {
            "channel": names[ch_idx] if ch_idx < len(names) else f"Ch{ch_idx}",
            "channel_index": ch_idx,
            "sigma": self.sigma_slider.value(),
            "percentile": self.pct_slider.value() * 0.5,
            "method": method,
            "invert": self.invert_check.isChecked(),
        }
        if method == "multiotsu":
            params["levels"] = self.levels_spin.value()
            params["selected_levels"] = self._selected_levels()
        return params

    def _apply_to_current_t(self):
        if self.data is None:
            return
        self.custom_timepoint_params[int(self.t_slider.value())] = dict(self._current_params())
        self._update_override_status()

    def _apply_to_range(self):
        if self.data is None:
            return
        start, end = sorted((int(self.range_start_spin.value()), int(self.range_end_spin.value())))
        start, end = max(0, min(start, self.T - 1)), max(0, min(end, self.T - 1))
        params = self._current_params()
        for t in range(start, end + 1):
            self.custom_timepoint_params[t] = dict(params)
        self.range_start_spin.setValue(start)
        self.range_end_spin.setValue(end)
        self._update_override_status()

    def _update_override_status(self):
        total = self.T if self.data is not None else 0
        self.override_status_label.setText(f"Customized: {len(self.custom_timepoint_params)} / {total} T")

    def _materialize_timepoint_params(self, default_params):
        params_by_t = [dict(default_params) for _ in range(self.T)]
        for t, params in self.custom_timepoint_params.items():
            if 0 <= t < self.T:
                params_by_t[t] = dict(params)
        return params_by_t

    # ── Computation and drawing ──────────────────────────────────────────

    def _compute(self, data, generation, t, p, ch_idx, sigma, method, percentile, invert, levels, selected):
        """(image, smoothed, mask, centroid, class_map, thresholds) with the alignment's calculations.

        Runs on the worker thread only, which alone reads and writes the caches.
        """
        img = data.get(t, p)[ch_idx]
        key = (generation, t, p, ch_idx, sigma)
        if key != self._smooth_key:
            self._smoothed = self.backend.gaussian(img, sigma)
            self._edges = np.histogram_bin_edges(self._smoothed.ravel(), bins=80)
            self._smooth_key = key
            self._class_key = None
        smoothed = self._smoothed
        class_map = None
        thresholds = np.array([])
        if method == "multiotsu":
            if self._class_key != (key, levels):
                self._class_thresholds, self._class_map = multiotsu_thresholds_and_classes(smoothed, levels)
                # Class histograms depend only on the image and the class map, not on the checked classes.
                self._class_counts = [np.histogram(smoothed[self._class_map == i], bins=self._edges)[0]
                                      for i in range(levels)]
                self._class_key = (key, levels)
            class_map, thresholds = self._class_map, self._class_thresholds
        mask, centroid = find_largest_mask_xy(smoothed, percentile, method=method, invert=invert, levels=levels,
                                              selected_levels=selected, class_map=class_map)
        return img, smoothed, mask, centroid, class_map, thresholds

    def _request_args(self):
        """The current controls as _compute arguments (t, p, ch_idx, sigma, method, percentile, invert, levels, selected)."""
        return (self.t_slider.value(), self.embryo_idx, self._channel_index(), self.sigma_slider.value(),
                self._method_code(), self.pct_slider.value() * 0.5, self.invert_check.isChecked(),
                self.levels_spin.value(), self._selected_levels())

    def _work(self, request, data, generation, args):
        """One redraw on the worker thread. Skipped when a newer request is already queued."""
        if request != self._request:
            return
        t, p, ch_idx, sigma, method, percentile, invert, levels, selected = args
        try:
            img, smoothed, mask, centroid, class_map, thresholds = self._compute(data, generation, *args)
            if data.T > 1:
                data.prefetch((t + 1) % data.T, p)
            rgba = np.ascontiguousarray(render_composite(img, mask, centroid, class_map=class_map,
                                                         selected_levels=selected))
            area = int(mask.sum())
            mean_val = float(img[mask].mean()) if mask.any() else 0.0
            cap = (f"Embryo {p}  |  Area: {area} px ({area / mask.size * 100:.1f}%)  |  "
                   f"Centroid: ({centroid[1]:.1f}, {centroid[0]:.1f})  |  Mean intensity: {mean_val:.1f}")
            # The mask keeps only the largest component; below 100% the crosshair can
            # sit on a different structure than the coloured overlay suggests.
            if class_map is not None and selected:
                selected_px = int(np.isin(class_map, selected).sum())
                if selected_px:
                    cap += f"  |  Largest component: {area / selected_px * 100:.0f}% of selected"
            q = roi = None
            if class_map is not None:
                counts = self._class_counts
            else:
                counts = [np.histogram(smoothed[~mask], bins=self._edges)[0],
                          np.histogram(smoothed[mask], bins=self._edges)[0]]
                q = np.percentile(smoothed, percentile)
                if method == "percentile_otsu_roi":
                    roi = roi_otsu_threshold(smoothed, q)
            hist = (self._edges, counts, class_map is not None, thresholds, q, roi)
        except Exception as e:
            self._relay.done.emit((request, args, e))
            return
        self._relay.done.emit((request, args, (rgba, cap, hist)))

    def _show(self, message):
        """Display a worker result on the GUI thread, unless the controls have moved on."""
        request, args, result = message
        if request != self._request:
            return
        t, p, ch_idx, sigma, method, percentile, invert, levels, selected = args
        if isinstance(result, Exception):
            self._stop_play()
            QMessageBox.critical(self, "Cannot read frame", f"T={t}, embryo {p}\n\n{result}")
            return
        rgba, cap, hist = result
        image = QImage(rgba.data, rgba.shape[1], rgba.shape[0], rgba.shape[1] * 4,
                       QImage.Format.Format_RGBA8888).copy()
        self.img_label.setPixmap(QPixmap.fromImage(image))
        self.cap_label.setText(cap)
        self._update_histogram(*hist, method, percentile, selected, invert)

    def _update(self):
        if self.data is None:
            return
        args = self._request_args()
        t, p, ch_idx, sigma, method, percentile, invert, levels, selected = args

        header = (f"T = {t}  |  {self.data.channel_names[ch_idx]}  |  sigma = {sigma}  |  "
                  f"method = {method}  |  percentile = {percentile}")
        if method == "multiotsu":
            header += f"  |  levels = {levels}  |  selected = {','.join(map(str, selected)) or 'none'}"
        if invert:
            header += "  |  INVERTED"
        self.header_label.setText(header)
        self._request += 1
        self._pool.submit(self._work, self._request, self.data, self._generation, args)

    def _update_histogram(self, edges, counts, by_class, thresholds, q, roi, method, percentile, selected, invert):
        """Draw precomputed counts. A count placed as the weight of its bin's left edge
        gives the same bars as ax.hist on the pixels themselves."""
        ax = self.hist_ax
        ax.clear()
        ax.set_box_aspect(1)
        if by_class:
            levels = len(counts)
            colors = [np.asarray(LEVEL_COLORS[i % len(LEVEL_COLORS)]) / 255 for i in range(levels)]
            labels = [f"Class {i} ({'selected' if i in selected else 'not displayed'})" for i in range(levels)]
            ax.hist([edges[:-1]] * levels, bins=edges, weights=counts, stacked=True, color=colors, label=labels)
            markers = []
            for i, threshold in enumerate(thresholds):
                ax.axvline(threshold, color="#8a6500", linestyle="--", linewidth=1.2,
                           label="Otsu boundaries" if i == 0 else "_nolegend_")
                markers.append(f"{i}/{i + 1}: {threshold:.6g}")
            note = ("Classes are numbered from 0 (darkest), matching the checkboxes. "
                    "Colours show classes before inclusion and largest-component selection. ")
            note += ("Otsu boundaries: " + "; ".join(markers) + "." if markers else
                     "Too few distinct intensities: all pixels assigned to class 0; no Otsu boundaries.")
        else:
            ax.hist([edges[:-1]] * 2, bins=edges, weights=counts, stacked=True, color=["#7a8793", "#ff3232"],
                    label=["Outside final mask", "Inside final mask (red overlay)"])
            gate = "Percentile threshold" if method == "percentile" else "Percentile gate"
            ax.axvline(q, color="#8a6500", linestyle="--", linewidth=1.2, label=f"{gate}: P{percentile:g} = {q:.6g}")
            note = "Colours show final mask after largest-component selection. "
            if method == "percentile_otsu_roi":
                if roi is not None:
                    ax.axvline(roi, color="#007c91", linestyle=":", linewidth=1.5,
                               label=f"ROI-derived Otsu threshold: {roi:.6g}")
                    note += "Otsu is fitted to the largest percentile region, then applied to the full frame."
                else:
                    note += "ROI empty or constant: masking uses the percentile threshold only."
            else:
                note += "Pixels must exceed the percentile threshold before inclusion in the final mask."
        if invert:
            note += " Invert Mask is ON: the threshold selection is complemented before keeping the largest component."
        self.hist_note.setText(note)
        ax.set_xlabel("Gaussian-smoothed intensity", fontsize=9)
        ax.set_ylabel("Pixel count", fontsize=9)
        ax.tick_params(labelsize=8)
        if edges[-1] > edges[0]:
            ax.set_xlim(edges[0], edges[-1])
        ax.set_ylim(bottom=0)
        ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.02), ncol=2, fontsize=8, frameon=False, borderaxespad=0)
        self.hist_canvas.draw_idle()

    # ── Animation ────────────────────────────────────────────────────────

    def _toggle_play(self):
        self.playing = not self.playing
        self.play_btn.setText("Pause" if self.playing else "Play")
        if self.playing:
            self._animate()
        else:
            self.animation_timer.stop()

    def _stop_play(self):
        if self.playing:
            self._toggle_play()

    def _animate(self):
        if not self.playing or self.data is None or self.T == 0:
            return
        self.t_slider.setValue((self.t_slider.value() + 1) % self.T)
        self.animation_timer.start(int(self.delay_spin.value() * 1000))

    # ── Save YAML ────────────────────────────────────────────────────────

    def _save_yaml(self):
        """Write {base}_P{p}_{channel}_threshold.yaml (ND2) or {base}_{channel}_threshold.yaml
        (TIFF) next to the input file."""
        if self.data is None:
            QMessageBox.warning(self, "No data", "Load a file first.")
            return
        # Compute on the worker thread (it owns the caches) and wait, so the diagnostics
        # describe exactly the current controls.
        args = self._request_args()
        t, p = args[0], args[1]
        try:
            img, _, mask, centroid, _, _ = self._pool.submit(self._compute, self.data, self._generation, *args).result()
        except Exception as e:
            QMessageBox.critical(self, "Cannot read frame", f"T={t}, embryo {p}\n\n{e}")
            return
        params = self._current_params()
        area = int(mask.sum())
        output = {
            "parameters": params,
            "timepoint_parameters": self._materialize_timepoint_params(params),
            "source": {
                "file": str(Path(self.file_path)),
                "image_shape": {"T": self.T, "P": self.P, "Y": self.Y, "X": self.X},
            },
            "diagnostics": {
                "time_point": t,
                "saved_at": datetime.datetime.now().isoformat(timespec="seconds"),
                "embryos": [{
                    "id": p,
                    "mask_area_px": area,
                    "mask_area_pct": round(area / mask.size * 100, 2),
                    "mean_intensity": round(float(img[mask].mean()), 2) if mask.any() else 0.0,
                    "centroid": [round(float(centroid[1]), 2), round(float(centroid[0]), 2)],
                }],
            },
        }
        source = Path(self.file_path)
        if self.data.is_nd2:
            fname = f"{source.stem}_P{p}_{params['channel']}_threshold.yaml"
        else:
            fname = f"{stem_without_ome(source)}_{params['channel']}_threshold.yaml"
        out_path = source.resolve().parent / fname
        try:
            with open(out_path, "w", encoding="utf-8") as fout:
                yaml.dump(output, fout, default_flow_style=False, sort_keys=False, allow_unicode=True)
        except OSError as e:
            QMessageBox.critical(self, "Cannot save", f"{out_path}\n\n{e}")
            return
        self.status_label.setText(f"Saved → {fname}")

    def closeEvent(self, event):
        self._stop_play()
        self._request += 1  # queued redraws see a newer request and skip
        self._pool.shutdown(wait=True)
        if self.data is not None:
            self.data.close()
            self.data = None
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = ThresholdApp()
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
