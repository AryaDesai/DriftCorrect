"""Window for the ND2 → TIFF conversion (runs nd2_to_tif.py as a worker)."""

import sys
from pathlib import Path

from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QFormLayout, QHBoxLayout, QLabel, QMessageBox, QPushButton, QSpinBox, QVBoxLayout, QWidget,
)

from common_gui import WorkerPanel, line_edit, path_row


class ConversionWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Convert ND2 to TIFF")
        self.resize(650, 480)
        self.input_folder = line_edit()
        self.output_folder = line_edit("Default: tifs subfolder inside the input folder")
        self.all_positions = QCheckBox("All embryo positions")
        self.all_positions.setChecked(True)
        self.position = QSpinBox()
        self.position.setRange(0, 1000000)
        self.position.setEnabled(False)
        self.position.setToolTip("Zero-based embryo position: 0 is the first position.")
        self.parallel = QCheckBox("Process positions in parallel")
        self.parallel.setChecked(True)
        self.parallel.setToolTip("Reads each ND2 file once and writes all positions at the same time.")
        self.concat_only = QCheckBox("Only concatenate existing TIFFs (skip conversion)")
        self.all_positions.toggled.connect(lambda on: (self.position.setEnabled(not on), self.parallel.setEnabled(on)))

        self.settings = QWidget()
        form = QFormLayout(self.settings)
        form.addRow("ND2 folder:", path_row(self.input_folder, "folder", "Select ND2 folder"))
        form.addRow("Output folder:", path_row(self.output_folder, "folder", "Select output folder"))
        form.addRow("", self.all_positions)
        form.addRow("Position index:", self.position)
        form.addRow("", self.parallel)
        form.addRow("", self.concat_only)
        self.run_button = QPushButton("Convert")
        self.run_button.clicked.connect(self.run)
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.setEnabled(False)
        self.panel = WorkerPanel()
        self.panel.on_finished = self._finished
        self.cancel_button.clicked.connect(self.panel.cancel)
        buttons = QHBoxLayout()
        buttons.addStretch()
        buttons.addWidget(self.cancel_button)
        buttons.addWidget(self.run_button)
        layout = QVBoxLayout(self)
        note = QLabel("Converts ND2 files in filename order, then joins each embryo's TIFFs across time.")
        note.setWordWrap(True)
        layout.addWidget(note)
        layout.addWidget(self.settings)
        layout.addLayout(buttons)
        layout.addWidget(self.panel, 1)

    def run(self):
        text = self.input_folder.text().strip()
        folder = Path(text).expanduser()
        if not text or not folder.is_dir():
            QMessageBox.warning(self, "Select input", "Select an existing ND2 folder.")
            return
        if not any(folder.glob("*.nd2")):
            QMessageBox.warning(self, "No ND2 files", "The selected folder contains no .nd2 files.")
            return
        args = [str(folder.resolve())]
        if self.output_folder.text().strip():
            args += ["--output_dir", str(Path(self.output_folder.text().strip()).expanduser().resolve())]
        if not self.all_positions.isChecked():
            args += ["--position", str(self.position.value())]
        args += ["--parallel", str(self.parallel.isChecked())]
        if self.concat_only.isChecked():
            args.append("--concat_only")
        self.settings.setEnabled(False)
        self.run_button.setEnabled(False)
        self.cancel_button.setEnabled(True)
        self.panel.start("convert-worker", args, "Converting…")

    def _finished(self, ok):
        self.settings.setEnabled(True)
        self.run_button.setEnabled(True)
        self.cancel_button.setEnabled(False)

    def closeEvent(self, event):
        event.accept() if self.panel.confirm_close(self) else event.ignore()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = ConversionWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
