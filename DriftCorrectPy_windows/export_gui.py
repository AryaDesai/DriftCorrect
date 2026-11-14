"""The Export window. It writes MP4 movies of an OME-TIFF or ND2 file, such as the input of the alignment or its
output. Each setting shows an explanation when the pointer rests on it.

The window runs export_movies.py as a worker.
"""

import sys
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QApplication, QComboBox, QDoubleSpinBox, QFormLayout, QHBoxLayout, QLabel, QMainWindow, QMessageBox, QPushButton,
    QSlider, QSpinBox, QVBoxLayout, QWidget,
)

from common_gui import WorkerPanel, line_edit, path_row, run_in_background
from useful_functions import FrameSource

# Each setting shows its explanation when the pointer rests on it.
HELP = {
    "movie": "The OME-TIFF or ND2 file to export. The movies are saved next to it.",
    "channel": "All channels writes one movie for each channel. A single channel writes one movie.",
    "view": "Maximum projection shows the brightest value along z at each pixel. One slice shows a single slice, counted from 1, which is the way to see z correction.",
    "compare": "A second OME-TIFF or ND2 file shown to the right of the first one, such as the unaligned movie next to the aligned one. Each side keeps its own size and brightness. Leave this empty for a movie of one file.",
    "fps": "The playback speed in frames per second. Each timepoint is one frame.",
    "contrast": "Whole movie sets the brightness once from timepoints spread over the movie, so a cell keeps its brightness from frame to frame. Each frame sets the brightness of every frame on its own, which shows dim frames better and can flicker.",
    "codec": "HEVC gives files about half the size of H.264 at the same quality. H.264 plays in more programs, such as older versions of PowerPoint and some web tools.",
    "quality": "From 1 to 100. Higher values keep more detail and give larger files. The default is 65.",
}

# The file dialogs show ND2 and TIFF files first.
MOVIE_FILTER = "ND2 or TIFF (*.nd2 *.tif *.tiff);;All files (*)"


def file_row(field, caption):
    """Return a file field and its Browse… button as one widget, so that the form can show or hide them together."""
    row = QWidget()
    layout = path_row(field, "file", caption, MOVIE_FILTER)
    layout.setContentsMargins(0, 0, 0, 0)
    row.setLayout(layout)
    return row


class ExportWindow(QMainWindow):
    """The window shows every setting at once. Export starts export_movies.py as a worker with these settings."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Export movies")
        self.setMinimumSize(640, 560)

        # These rows choose the movie, the channel and the view. The slice row shows only when one slice is chosen.
        self.movie_edit = line_edit("Select an OME-TIFF or ND2 file")
        self.movie_edit.editingFinished.connect(self._movie_changed)
        self.movie_edit.textChanged.connect(lambda: self._update())
        movie_row = file_row(self.movie_edit, "Select movie")
        for child in movie_row.findChildren(QPushButton):
            child.clicked.connect(self._movie_changed)
        self.channel_combo = QComboBox()
        self.channel_combo.addItem("All channels", None)
        self.view_combo = QComboBox()
        self.view_combo.addItem("Maximum projection", "max")
        self.view_combo.addItem("One slice", "slice")
        self.view_combo.currentIndexChanged.connect(lambda: self._update())
        self.slice_spin = QSpinBox()
        self.slice_spin.setRange(1, 10000)
        self.slice_count = QLabel("")
        self.slice_count.setStyleSheet("color: gray;")
        slice_layout = QHBoxLayout()
        slice_layout.setContentsMargins(0, 0, 0, 0)
        slice_layout.addWidget(self.slice_spin)
        slice_layout.addWidget(self.slice_count)
        slice_layout.addStretch()
        self.slice_row = QWidget()
        self.slice_row.setLayout(slice_layout)
        # These rows choose the movie to compare and how the movie is played and encoded.
        self.compare_edit = line_edit("Optional second movie shown on the right")
        compare_row = file_row(self.compare_edit, "Select a movie to compare")
        self.fps_spin = QDoubleSpinBox()
        self.fps_spin.setRange(0.01, 1000.0)
        self.fps_spin.setDecimals(2)
        self.fps_spin.setValue(2.0)
        self.fps_spin.setSuffix(" fps")
        self.contrast_combo = QComboBox()
        self.contrast_combo.addItem("Whole movie", "movie")
        self.contrast_combo.addItem("Each frame", "frame")
        self.codec_combo = QComboBox()
        self.codec_combo.addItem("HEVC", "hevc")
        self.codec_combo.addItem("H.264", "h264")
        self.quality_slider = QSlider(Qt.Orientation.Horizontal)
        self.quality_slider.setRange(1, 100)
        self.quality_slider.setValue(65)
        quality_label = QLabel("65")
        quality_label.setMinimumWidth(30)
        self.quality_slider.valueChanged.connect(lambda value: quality_label.setText(str(value)))
        quality_layout = QHBoxLayout()
        quality_layout.setContentsMargins(0, 0, 0, 0)
        quality_layout.addWidget(self.quality_slider, 1)
        quality_layout.addWidget(quality_label)
        quality_row = QWidget()
        quality_row.setLayout(quality_layout)

        # Every row and its label show the explanation of the setting when the pointer rests on them.
        self.form = QFormLayout()
        for label, widget, key in (("Movie:", movie_row, "movie"), ("Channel:", self.channel_combo, "channel"),
                                   ("View:", self.view_combo, "view"), ("Slice:", self.slice_row, "view"),
                                   ("Compare with:", compare_row, "compare"), ("Speed:", self.fps_spin, "fps"),
                                   ("Contrast:", self.contrast_combo, "contrast"), ("Codec:", self.codec_combo, "codec"),
                                   ("Quality:", quality_row, "quality")):
            name = QLabel(label)
            for item in [name, widget] + widget.findChildren(QWidget):
                item.setToolTip(HELP[key])
            self.form.addRow(name, widget)
        self.settings = QWidget()
        self.settings.setLayout(self.form)

        # The buttons sit above the log of the worker.
        self.run_button = QPushButton("Export")
        self.run_button.clicked.connect(self._run)
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.setEnabled(False)
        self.panel = WorkerPanel()
        self.panel.on_finished = self._finished
        self.cancel_button.clicked.connect(self.panel.cancel)
        buttons = QHBoxLayout()
        buttons.addStretch()
        buttons.addWidget(self.cancel_button)
        buttons.addWidget(self.run_button)
        layout = QVBoxLayout()
        layout.addWidget(self.settings)
        layout.addLayout(buttons)
        layout.addWidget(self.panel, 1)
        container = QWidget()
        container.setLayout(layout)
        self.setCentralWidget(container)
        self._update()

    def _update(self):
        """Show the slice row only for one slice, and allow Export once a movie is chosen and no export runs."""
        one_slice = self.view_combo.currentData() == "slice"
        self.form.setRowVisible(self.slice_row, one_slice)
        has_movie = bool(self.movie_edit.text().strip())
        self.run_button.setEnabled(has_movie and not self.panel.running)

    def _movie_changed(self):
        """List the channels and count the slices of the selected movie."""
        path = Path(self.movie_edit.text().strip()).expanduser()
        if not path.is_file():
            return

        def read():
            try:
                source = FrameSource(path)
                names, depth = list(source.channel_names[:source.C]), source.Z
                source.close()
                return path, names, depth
            except Exception:
                return path, [], 0

        run_in_background(read, self._movie_ready, self)

    def _movie_ready(self, result):
        """Fill in the channels and the number of slices, unless the user chose another movie meanwhile."""
        path, names, depth = result
        if path != Path(self.movie_edit.text().strip()).expanduser():
            return
        self.channel_combo.clear()
        self.channel_combo.addItem("All channels", None)
        for name in names:
            self.channel_combo.addItem(name, name)
        if depth:
            self.slice_spin.setMaximum(depth)
            self.slice_count.setText(f"of {depth}")

    def _run(self):
        """Check the files and start the worker with the settings of the window."""
        movie = Path(self.movie_edit.text().strip()).expanduser()
        if not movie.is_file():
            QMessageBox.warning(self, "Invalid movie", "Select an existing OME-TIFF or ND2 file.")
            return
        args = [str(movie.resolve())]
        compare = self.compare_edit.text().strip()
        if compare:
            compare_path = Path(compare).expanduser()
            if not compare_path.is_file():
                QMessageBox.warning(self, "Invalid movie to compare",
                                    "Select an existing OME-TIFF or ND2 file, or leave the field empty.")
                return
            args += ["--compare", str(compare_path.resolve())]
        channel = self.channel_combo.currentData()
        if channel is not None:
            args += ["--channel", str(self.channel_combo.currentIndex() - 1)]
        if self.view_combo.currentData() == "slice":
            args += ["--slice", str(self.slice_spin.value())]
        args += ["--fps", str(self.fps_spin.value()), "--contrast", self.contrast_combo.currentData(),
                 "--codec", self.codec_combo.currentData(), "--quality", str(self.quality_slider.value())]
        self.settings.setEnabled(False)
        self.run_button.setEnabled(False)
        self.cancel_button.setEnabled(True)
        self.panel.start("export-worker", args, "Exporting…")

    def _finished(self, ok):
        """Unlock the settings when the worker stops."""
        self.settings.setEnabled(True)
        self.cancel_button.setEnabled(False)
        self._update()

    def closeEvent(self, event):
        event.accept() if self.panel.confirm_close(self) else event.ignore()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = ExportWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
