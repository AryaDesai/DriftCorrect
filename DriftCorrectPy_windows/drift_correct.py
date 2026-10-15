"""Entry point for the drift-correction tools.

With no arguments it opens the launcher. "--tool MODE [ARGS…]" runs one tool:
a window (convert-gui, mask-gui, align-gui, z-gui, manual-gui) or a worker
process that a window starts (convert-worker, align-worker, z-worker,
manual-worker). Workers take the same arguments as their scripts.
"""



import argparse
import sys

GUI_MODES = ("convert-gui", "mask-gui", "align-gui")
WORKER_MODES = ("convert-worker", "align-worker")

TOOLS = (
    ("Convert ND2 to TIFF", "convert-gui"),
    ("Mask embryo", "mask-gui"),
    ("Align movie", "align-gui"),

)


def launcher_main():
    from PyQt6.QtCore import QProcess
    from PyQt6.QtWidgets import QApplication, QDialog, QLabel, QMessageBox, QPushButton, QVBoxLayout

    from tool_runtime import tool_command

    class DriftCorrectDialog(QDialog):
        def __init__(self):
            super().__init__()
            self.setWindowTitle("Drift correction")
            self.setMinimumWidth(340)
            self.processes = {}
            layout = QVBoxLayout(self)
            layout.setSpacing(12)
            layout.addWidget(QLabel("What do you want to do?"))
            for label, mode in TOOLS:
                button = QPushButton(label)
                button.setMinimumHeight(42)
                button.clicked.connect(lambda _=False, m=mode, b=button: self.launch(m, b))
                layout.addWidget(button)

        def launch(self, mode, button):
            process = QProcess(self)
            process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
            self.processes[process] = [button, ""]
            button.setEnabled(False)
            process.readyReadStandardOutput.connect(lambda: self.read_output(process))
            process.errorOccurred.connect(lambda error: self.process_error(process, error))
            process.finished.connect(lambda code, status: self.finished(process, code, status))
            program, arguments = tool_command(mode)
            process.start(program, arguments)

        def read_output(self, process):
            if process in self.processes:
                output = bytes(process.readAllStandardOutput()).decode(errors="replace")
                self.processes[process][1] = (self.processes[process][1] + output)[-12000:]

        def process_error(self, process, error):
            if error == QProcess.ProcessError.FailedToStart and process in self.processes:
                self.processes[process][1] = process.errorString()
                self.finished(process, -1, QProcess.ExitStatus.CrashExit)

        def finished(self, process, code, status):
            if process not in self.processes:
                return
            self.read_output(process)
            button, output = self.processes.pop(process)
            button.setEnabled(True)
            process.deleteLater()
            if code != 0 or status != QProcess.ExitStatus.NormalExit:
                message = QMessageBox(self)
                message.setWindowTitle("Tool stopped")
                message.setIcon(QMessageBox.Icon.Warning)
                message.setText(f"{button.text()} stopped with an error.")
                message.setDetailedText(output or f"Exit code: {code}")
                message.exec()

        def closeEvent(self, event):
            if self.processes:
                QMessageBox.information(self, "Tools open", "Close the tool windows before closing the launcher.")
                event.ignore()
            else:
                event.accept()

    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = DriftCorrectDialog()
    window.show()
    return app.exec()


def entry_point(mode):
    """Explicit imports so Nuitka and PyInstaller find every tool"""
    if mode == "convert-gui":
        from nd2_to_tif_gui import main
    elif mode == "mask-gui":
        from find_threshold import main
    elif mode == "align-gui":
        from centroid_align_xy_gui import main
    elif mode == "convert-worker":
        from nd2_to_tif import main
    elif mode == "align-worker":
        from centroid_align_xy import main

    else:
        main = launcher_main
    return main


def main():
    parser = argparse.ArgumentParser(description="Drift correction tools")
    parser.add_argument("--tool", choices=GUI_MODES + WORKER_MODES)
    # Parse only the routing prefix, so that worker flags (and --help) go to the worker's own parser.
    if sys.argv[1:2] == ["--tool"]:
        options = parser.parse_args(sys.argv[1:3])
        remaining = sys.argv[3:]
    else:
        options = parser.parse_args()
        remaining = []
    if remaining and options.tool not in WORKER_MODES:
        parser.error("unrecognized arguments: " + " ".join(remaining))
    sys.argv = [sys.argv[0], *remaining]
    code = entry_point(options.tool)()
    return code or 0


if __name__ == "__main__":
  
    from multiprocessing import freeze_support
    freeze_support()
    raise SystemExit(main())
