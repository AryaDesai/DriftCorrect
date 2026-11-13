"""The Alignment window. It corrects a movie in xy and z, in xy only, or in z only.

The user picks a movie and a channel and runs. When the chosen settings use the embryo mask, the Mask window opens
from here. The settings that change how the correction works are under Advanced options, each with an explanation.
The window runs centroid_align_xy.py as a worker.
"""

import sys
from pathlib import Path

from PyQt6.QtCore import QEvent, QProcess
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QHBoxLayout, QLabel, QLineEdit, QMainWindow,
    QMessageBox, QPushButton, QScrollArea, QSpinBox, QTabBar, QToolButton, QVBoxLayout, QWidget,
)

from backend import get_backend
from common_gui import WorkerPanel, line_edit, path_row, run_in_background
from tool_runtime import tool_command
from useful_functions import FrameSource, stem_without_ome

MODES = ("xyz", "xy", "z")
NUCLEAR_NAMES = ("mcherry", "h2b", "nuc", "dapi", "hoechst")


def note(text):
    """A short explanation shown under a setting."""
    label = QLabel(text)
    label.setWordWrap(True)
    label.setStyleSheet("color: gray; font-size: 11px;")
    return label


class FollowSettings(QWidget):
    """The part of the image that image matching or z correction follows."""

    def __init__(self):
        super().__init__()
        self.region_combo = QComboBox()
        self.region_combo.addItem("Whole frame", "whole")
        self.region_combo.addItem("Embryo mask", "mask")
        self.region_combo.addItem("Box", "box")
        self.box_edit = QLineEdit()
        self.box_edit.setPlaceholderText("x, y, width, height in pixels of the first timepoint")
        self.box_edit.setEnabled(False)
        self.region_combo.currentIndexChanged.connect(lambda: self.box_edit.setEnabled(self.region_combo.currentData() == "box"))
        row = QHBoxLayout()
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.region_combo)
        row.addWidget(self.box_edit, 1)
        self.setLayout(row)

    def region(self):
        return self.region_combo.currentData()

    def arguments(self, prefix):
        """Return the worker arguments. Raises ValueError when the box is not four whole numbers."""
        args = [f"--{prefix}_region", self.region()]
        if self.region() == "box":
            parts = self.box_edit.text().replace(",", " ").split()
            if len(parts) != 4 or not all(part.isdigit() for part in parts):
                raise ValueError("Give the box as four whole numbers: x, y, width, height.")
            args += [f"--{prefix}_box", *parts]
        return args


class AlignWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Alignment")
        self.setMinimumSize(760, 700)
        self.mask_processes = []

        self.tabs = QTabBar()
        for title in ("XYZ", "XY only", "Z only"):
            self.tabs.addTab(title)
        self.tabs.currentChanged.connect(self._update_visible)

        self.movie_edit = line_edit("Select an OME-TIFF or ND2 file")
        self.movie_edit.editingFinished.connect(self._movie_changed)
        self.movie_edit.textChanged.connect(lambda: self._update_visible())
        self.channel_combo = QComboBox()
        self.channel_combo.setEditable(True)
        self.channel_note = note("The channel whose pattern is followed. A nuclear marker is the best choice, because its "
                                 "pattern stays the same from one timepoint to the next.")
        self.yaml_edit = line_edit("No mask yet")
        self.yaml_edit.textChanged.connect(lambda: self._update_visible())
        self.mask_button = QPushButton("Make mask…")
        self.mask_button.clicked.connect(self._make_mask)
        mask_row = path_row(self.yaml_edit, "file", "Select threshold YAML", "YAML files (*.yaml *.yml);;All files (*)")
        mask_row.addWidget(self.mask_button)
        self.mask_row = QWidget()
        mask_row.setContentsMargins(0, 0, 0, 0)
        self.mask_row.setLayout(mask_row)
        self.mask_note = note("These settings use the embryo mask. Make mask opens the threshold window with a suggested "
                              "threshold. Adjust it, save, and the saved file appears here. You can also browse to a "
                              "threshold YAML file you saved before.")

        self.form = QFormLayout()
        movie_row = QWidget()
        movie_layout = path_row(self.movie_edit, "file", "Select movie", "ND2 or TIFF (*.nd2 *.tif *.tiff);;All files (*)")
        movie_layout.setContentsMargins(0, 0, 0, 0)
        movie_row.setLayout(movie_layout)
        for child in movie_row.findChildren(QPushButton):
            child.clicked.connect(self._movie_changed)
        self.form.addRow("Movie:", movie_row)
        self.form.addRow("Channel:", self.channel_combo)
        self.form.addRow("", self.channel_note)
        self.mask_label = QLabel("Embryo mask:")
        self.form.addRow(self.mask_label, self.mask_row)
        self.form.addRow("", self.mask_note)

        self.advanced_button = QToolButton()
        self.advanced_button.setText("Advanced options")
        self.advanced_button.setCheckable(True)
        self.advanced_button.setStyleSheet("QToolButton { border: none; font-weight: bold; }")
        self.advanced_button.toggled.connect(self._update_visible)
        self.form.addRow(self.advanced_button)
        self._build_advanced()

        settings = QWidget()
        settings.setLayout(self.form)
        self.settings = QScrollArea()
        self.settings.setWidgetResizable(True)
        self.settings.setWidget(settings)

        self.run_button = QPushButton("Run")
        self.run_button.clicked.connect(self._run)
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.setEnabled(False)
        self.hint_label = QLabel("")
        self.hint_label.setStyleSheet("color: gray;")
        self.panel = WorkerPanel()
        self.panel.on_finished = self._finished
        self.cancel_button.clicked.connect(self.panel.cancel)
        buttons = QHBoxLayout()
        # CUDA start-up takes seconds, so the backend is detected after the window is shown.
        backend_label = QLabel("Compute: detecting…")
        run_in_background(lambda: get_backend().name, lambda name: backend_label.setText(f"Compute: {name}"), self)
        buttons.addWidget(backend_label)
        buttons.addStretch()
        buttons.addWidget(self.hint_label)
        buttons.addWidget(self.cancel_button)
        buttons.addWidget(self.run_button)
        layout = QVBoxLayout()
        layout.addWidget(self.tabs)
        layout.addWidget(self.settings, 2)
        layout.addLayout(buttons)
        layout.addWidget(self.panel, 1)
        container = QWidget()
        container.setLayout(layout)
        self.setCentralWidget(container)
        self._update_visible()

    def _advanced_row(self, group, label, widget, text):
        """Add a setting with its explanation to the advanced options. `group` is "xy", "z" or "output"."""
        name = QLabel(label) if label else QLabel("")
        explanation = note(text)
        self.form.addRow(name, widget)
        self.form.addRow("", explanation)
        self.advanced.append((group, name, widget, explanation))
        return widget

    def _build_advanced(self):
        self.advanced = []
        self.xy_heading = QLabel("XY")
        self.z_heading = QLabel("Z")
        self.output_heading = QLabel("Output")
        for heading in (self.xy_heading, self.z_heading, self.output_heading):
            heading.setStyleSheet("font-weight: bold;")

        self.form.addRow(self.xy_heading)
        self.method_combo = QComboBox()
        self.method_combo.addItem("Image matching", "image")
        self.method_combo.addItem("Mask centroid", "centroid")
        self.method_combo.currentIndexChanged.connect(self._update_visible)
        self._advanced_row("xy", "Method:", self.method_combo,
                           "Image matching compares each timepoint with the one before it. It tries shifts and small turns "
                           "and keeps the one where the two images differ least. Mask centroid moves the centre of the "
                           "embryo mask to the middle of the frame, without turning.")
        self.xy_follow = FollowSettings()
        self.xy_follow.region_combo.currentIndexChanged.connect(self._update_visible)
        self._advanced_row("image", "Follow:", self.xy_follow,
                           "The part of the image that the matching compares. Whole frame uses every pixel. Embryo mask "
                           "uses the tissue only. A box follows only the cells inside it.")
        self.hold_check = QCheckBox("Hold the body in place with the embryo mask")
        self.hold_check.setChecked(True)
        self.hold_check.toggled.connect(self._update_visible)
        self._advanced_row("image", "", self.hold_check,
                           "Matching alone follows the cells. When cells move through the body, the frame slowly travels "
                           "with them. With this on, the embryo mask keeps the body in the middle of the frame and "
                           "pointing the same way.")
        self.smoothing_spin = QDoubleSpinBox()
        self.smoothing_spin.setRange(0, 1000)
        self.smoothing_spin.setDecimals(1)
        self.smoothing_spin.setValue(10)
        self._advanced_row("hold", "Averaging (timepoints):", self.smoothing_spin,
                           "The mask is rough at a single timepoint, so its position and direction are averaged over about "
                           "this many timepoints. A small value follows the mask closely and can wobble. A large value is "
                           "steadier and lets the body glide further before it is pulled back.")
        self.angle_spin = QDoubleSpinBox()
        self.angle_spin.setRange(0, 45)
        self.angle_spin.setDecimals(1)
        self.angle_spin.setValue(3)
        self._advanced_row("image", "Largest turn (degrees):", self.angle_spin,
                           "The largest turn between two neighbouring timepoints that the matching looks for. With 0 it "
                           "only shifts and never turns.")
        self.shift_combo = QComboBox()
        self.shift_combo.addItem("Sub-pixel (bilinear interpolation)", "subpixel")
        self.shift_combo.addItem("Whole pixels (no interpolation)", "integer")
        self._advanced_row("centroid", "Shift:", self.shift_combo,
                           "Sub-pixel moves by the exact amount and interpolates the intensities. Whole pixels rounds the "
                           "shift and keeps the original intensities.")

        self.form.addRow(self.z_heading)
        self.z_follow = FollowSettings()
        self.z_follow.region_combo.currentIndexChanged.connect(self._update_visible)
        self._advanced_row("z", "Follow:", self.z_follow,
                           "The part of the image that must stay in the same slice. To follow only some cells, give a box "
                           "over cells that should not move in z.")
        self.span_spin = QSpinBox()
        self.span_spin.setRange(1, 50)
        self.span_spin.setValue(5)
        self._advanced_row("z", "Also compare this many timepoints back:", self.span_spin,
                           "A slow movement is too small to measure between neighbouring timepoints. Each timepoint is also "
                           "compared with an earlier one, where the movement has added up. With 1 only neighbours are "
                           "compared.")
        self.drop_check = QCheckBox("Drop time points with z shifts above")
        self.drop_spin = QSpinBox()
        self.drop_spin.setRange(1, 1000)
        self.drop_spin.setValue(5)
        self.drop_spin.setSuffix(" slices")
        drop = QHBoxLayout()
        drop.setContentsMargins(0, 0, 0, 0)
        drop.addWidget(self.drop_check)
        drop.addWidget(self.drop_spin)
        drop.addStretch()
        drop_row = QWidget()
        drop_row.setLayout(drop)
        self._advanced_row("z", "", drop_row,
                           "Leaves out timepoints whose z movement from the timepoint before them is larger than this, for "
                           "example after the stage was moved. Later timepoints are still corrected for that movement.")

        self.form.addRow(self.output_heading)
        self.enlarge_check = QCheckBox("Enlarge the canvas and the stack so that nothing is cut off")
        self.enlarge_check.setChecked(True)
        self._advanced_row("output", "", self.enlarge_check,
                           "Adds empty pixels around the frame and empty slices to the stack, so that data moved by the "
                           "correction stays in the file. With this off the file keeps its size and data that moves "
                           "outside is lost.")
        self.fps_spin = QDoubleSpinBox()
        self.fps_spin.setRange(0.01, 1000.0)
        self.fps_spin.setDecimals(2)
        self.fps_spin.setValue(2.0)
        self.fps_spin.setSuffix(" fps")
        self._advanced_row("output", "Movie speed:", self.fps_spin,
                           "The playback speed of the MP4 movies that are written next to the corrected file.")
        self.low_memory_check = QCheckBox("Use low-memory streaming")
        self.low_memory_check.setChecked(True)
        self._advanced_row("output", "", self.low_memory_check,
                           "Reads the movie from disk a second time when writing, instead of keeping it in memory. Leave "
                           "this on when the file is larger than the available memory. Turning it off is faster for small "
                           "files.")
        self.cpu_check = QCheckBox("Use CPU only")
        self._advanced_row("output", "", self.cpu_check, "Ignores the GPU. The GPU is faster when one is available.")

    # The state of the window

    def mode(self):
        return MODES[self.tabs.currentIndex()]

    def does_xy(self):
        return self.mode() != "z"

    def does_z(self):
        return self.mode() != "xy"

    def image_method(self):
        return self.does_xy() and self.method_combo.currentData() == "image"

    def needs_mask(self):
        """The embryo mask is needed for the centroid method, for holding the body, and for following the mask."""
        xy = self.does_xy() and (not self.image_method() or self.hold_check.isChecked() or self.xy_follow.region() == "mask")
        return xy or (self.does_z() and self.z_follow.region() == "mask")

    def _update_visible(self, *_):
        """Show the settings that the chosen tab and method use."""
        show = self.advanced_button.isChecked()
        self.advanced_button.setText(("▾ " if show else "▸ ") + "Advanced options")
        image = self.image_method()
        visible = {
            "xy": self.does_xy(), "image": image, "hold": image and self.hold_check.isChecked(),
            "centroid": self.does_xy() and not image, "z": self.does_z(), "output": True,
        }
        for group, *widgets in self.advanced:
            for widget in widgets:
                widget.setVisible(show and visible[group])
        self.xy_heading.setVisible(show and self.does_xy())
        self.z_heading.setVisible(show and self.does_z())
        self.output_heading.setVisible(show)
        needs = self.needs_mask()
        for widget in (self.mask_label, self.mask_row, self.mask_note):
            widget.setVisible(needs)
        has_movie = bool(self.movie_edit.text().strip())
        self.mask_button.setEnabled(has_movie)
        missing = needs and not self.yaml_edit.text().strip()
        self.hint_label.setText("Make the mask first" if has_movie and missing else "")
        self.run_button.setText({"xyz": "Run xyz alignment", "xy": "Run xy alignment", "z": "Run z correction"}[self.mode()])
        self.run_button.setEnabled(has_movie and not missing and not self.panel.running)

    # The movie and its mask

    def _movie_changed(self):
        """List the channels of the selected movie and look for a mask that was saved for it."""
        path = Path(self.movie_edit.text().strip()).expanduser()
        if not path.is_file():
            return

        def read():
            try:
                source = FrameSource(path)
                names = list(source.channel_names[:source.C])
                source.close()
                return path, names
            except Exception:
                return path, []

        run_in_background(read, self._channels_ready, self)
        self._find_mask()

    def _channels_ready(self, result):
        path, names = result
        if path != Path(self.movie_edit.text().strip()).expanduser():
            return
        self.channel_combo.clear()
        self.channel_combo.addItems(names)
        # Start on a channel whose name looks like a nuclear marker.
        nuclear = [i for i, name in enumerate(names) if any(key in name.lower() for key in NUCLEAR_NAMES)]
        if names:
            self.channel_combo.setCurrentIndex(nuclear[0] if nuclear else 0)

    def _find_mask(self):
        """Fill in the newest threshold YAML file that the Mask window saved next to the movie."""
        path = Path(self.movie_edit.text().strip()).expanduser()
        if not path.is_file():
            return
        stem = path.stem if path.suffix.lower() == ".nd2" else stem_without_ome(path)
        found = sorted(path.parent.glob(f"{stem}_*_threshold.yaml"), key=lambda p: p.stat().st_mtime)
        current = self.yaml_edit.text().strip()
        if found and (not current or Path(current).parent == path.parent):
            self.yaml_edit.setText(str(found[-1]))
        elif not found and current and Path(current).parent == path.parent and not Path(current).is_file():
            self.yaml_edit.setText("")

    def _make_mask(self):
        """Open the Mask window on the movie, starting on the chosen channel with a suggested threshold."""
        path = Path(self.movie_edit.text().strip()).expanduser()
        if not path.is_file():
            QMessageBox.warning(self, "Invalid movie", "Select an existing OME-TIFF or ND2 file.")
            return
        program, arguments = tool_command("mask-gui", ["--file", str(path), "--channel", str(max(0, self.channel_combo.currentIndex()))])
        process = QProcess(self)
        process.finished.connect(lambda *_: self._find_mask())
        process.start(program, arguments)
        self.mask_processes.append(process)

    def event(self, event):
        # When the user comes back from the Mask window, pick up the mask that was saved.
        if event.type() == QEvent.Type.WindowActivate:
            self._find_mask()
        return super().event(event)

    # Running

    def _run(self):
        movie = Path(self.movie_edit.text().strip()).expanduser()
        if not movie.is_file():
            QMessageBox.warning(self, "Invalid movie", "Select an existing OME-TIFF or ND2 file.")
            return
        args = ["--input", str(movie.resolve())]
        if self.needs_mask():
            yaml_path = Path(self.yaml_edit.text().strip()).expanduser()
            if not yaml_path.is_file():
                QMessageBox.warning(self, "No mask", "These settings use the embryo mask. Make the mask first, or select "
                                                     "a threshold YAML file.")
                return
            args.insert(0, str(yaml_path.resolve()))
        channel = self.channel_combo.currentText().strip()
        try:
            if not self.does_xy():
                args += ["--xy_method", "none"]
            elif self.image_method():
                args += ["--xy_method", "image", *self.xy_follow.arguments("xy"),
                         "--xy_smoothing", str(self.smoothing_spin.value()), "--xy_max_angle", str(self.angle_spin.value())]
                if channel:
                    args += ["--xy_channel", channel]
                if not self.hold_check.isChecked():
                    args.append("--xy_no_hold")
            else:
                args += ["--xy_method", "centroid", "--shift_mode", self.shift_combo.currentData()]
            if self.does_z():
                args += ["--z_correct", *self.z_follow.arguments("z"), "--z_span", str(self.span_spin.value())]
                if channel:
                    args += ["--z_channel", channel]
                if self.drop_check.isChecked():
                    args += ["--z_drop_above", str(self.drop_spin.value())]
        except ValueError as error:
            QMessageBox.warning(self, "Invalid box", str(error))
            return
        args += ["--fps", str(self.fps_spin.value())]
        if not self.enlarge_check.isChecked():
            args.append("--no_enlarge_canvas")
        if self.low_memory_check.isChecked():
            args.append("--low_memory")
        if self.cpu_check.isChecked():
            args.append("--cpu")
        self.settings.setEnabled(False)
        self.tabs.setEnabled(False)
        self.run_button.setEnabled(False)
        self.cancel_button.setEnabled(True)
        self.panel.start("align-worker", args, "Running…")

    def _finished(self, ok):
        self.settings.setEnabled(True)
        self.tabs.setEnabled(True)
        self.cancel_button.setEnabled(False)
        self._update_visible()

    def closeEvent(self, event):
        event.accept() if self.panel.confirm_close(self) else event.ignore()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = AlignWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
