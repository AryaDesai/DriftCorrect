"""Window for XY centroid alignment (runs centroid_align_xy.py as a worker)."""

import sys
from pathlib import Path

from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QHBoxLayout, QLabel, QMainWindow, QMessageBox,
    QPushButton, QVBoxLayout, QWidget,
)

from backend import get_backend
from common_gui import WorkerPanel, line_edit, path_row, run_in_background


class CentroidAlignWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("XY Centroid Alignment")
        self.setMinimumWidth(700)
        self.yaml_edit = line_edit("Select a threshold YAML file")
        self.fps_spin = QDoubleSpinBox()
        self.fps_spin.setRange(0.01, 1000.0)
        self.fps_spin.setDecimals(2)
        self.fps_spin.setValue(2.0)
        self.fps_spin.setSuffix(" fps")
        self.use_nd2_check = QCheckBox("Load directly from the raw ND2 file")
        self.use_nd2_check.setToolTip("Uses the ND2 path stored in the YAML instead of the per-embryo TIFF.")
        self.enlarge_canvas_check = QCheckBox("Enlarge canvas to prevent clipping")
        self.enlarge_canvas_check.setChecked(True)
        self.enlarge_canvas_check.setToolTip(
            "Two-pass alignment: calculates all shifts first, expands the canvas, then applies the shifts. "
            "No edge data is lost. Turning this off may clip edge data.")
        self.shift_combo = QComboBox()
        self.shift_combo.addItem("Sub-pixel (bilinear interpolation)", "subpixel")
        self.shift_combo.addItem("Whole pixels (no interpolation)", "integer")
        self.shift_combo.setToolTip(
            "Sub-pixel: exact shift, intensities are interpolated (the old CPU result).\n"
            "Whole pixels: shift rounded to whole pixels, original intensities kept (the old GPU result).")
        self.low_memory_check = QCheckBox("Use low-memory streaming")
        self.low_memory_check.setToolTip(
            "Reads frames again in the second pass instead of keeping them in memory. "
            "Turn this on if the file is larger than the available RAM.")
        self.cpu_check = QCheckBox("Use CPU only")
        self.cpu_check.setToolTip("Ignore the GPU. Results are identical; the GPU is faster.")
        form = QFormLayout()
        form.addRow("Threshold YAML:", path_row(self.yaml_edit, "file", "Select threshold YAML",
                                                 "YAML files (*.yaml *.yml);;All files (*)"))
        form.addRow("Output video speed:", self.fps_spin)
        form.addRow("Shift:", self.shift_combo)
        form.addRow("", self.use_nd2_check)
        form.addRow("", self.enlarge_canvas_check)
        form.addRow("", self.low_memory_check)
        form.addRow("", self.cpu_check)
        self.settings = QWidget()
        self.settings.setLayout(form)
        self.run_button = QPushButton("Run alignment")
        self.run_button.clicked.connect(self._run)
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.setEnabled(False)
        self.panel = WorkerPanel()
        self.panel.on_finished = self._finished
        self.cancel_button.clicked.connect(self.panel.cancel)
        buttons = QHBoxLayout()
        # CUDA start-up takes seconds; detect it after the window is shown.
        backend_label = QLabel("Compute: detecting…")
        run_in_background(lambda: get_backend().name, lambda name: backend_label.setText(f"Compute: {name}"), self)
        buttons.addWidget(backend_label)
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

    def _run(self):
        yaml_path = Path(self.yaml_edit.text().strip()).expanduser()
        if not self.yaml_edit.text().strip() or not yaml_path.is_file():
            QMessageBox.warning(self, "Invalid YAML file", "Select an existing YAML file.")
            return
        if yaml_path.suffix.lower() not in {".yaml", ".yml"}:
            answer = QMessageBox.question(self, "Unexpected file type",
                                          "The selected file does not have a .yaml or .yml extension. Continue anyway?")
            if answer != QMessageBox.StandardButton.Yes:
                return
        args = [str(yaml_path.resolve()), "--fps", str(self.fps_spin.value()), "--shift_mode", self.shift_combo.currentData()]
        if self.use_nd2_check.isChecked():
            args.append("--use_nd2")
        if not self.enlarge_canvas_check.isChecked():
            args.append("--no_enlarge_canvas")
        if self.low_memory_check.isChecked():
            args.append("--low_memory")
        if self.cpu_check.isChecked():
            args.append("--cpu")
        self.settings.setEnabled(False)
        self.run_button.setEnabled(False)
        self.cancel_button.setEnabled(True)
        self.panel.start("align-worker", args, "Running…")

    def _finished(self, ok):
        self.settings.setEnabled(True)
        self.run_button.setEnabled(True)
        self.cancel_button.setEnabled(False)

    def closeEvent(self, event):
        event.accept() if self.panel.confirm_close(self) else event.ignore()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = CentroidAlignWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
