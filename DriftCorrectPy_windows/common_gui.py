"""Widgets shared by the tool windows: path rows and a worker-process panel."""

import codecs
import threading
from pathlib import Path

from PyQt6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, pyqtSignal
from PyQt6.QtGui import QTextCursor
from PyQt6.QtWidgets import (
    QFileDialog, QHBoxLayout, QLabel, QLineEdit, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton,
    QVBoxLayout, QWidget,
)

from tool_runtime import tool_command


def path_row(field, kind="folder", caption="Select", filters="All files (*)"):
    """A line edit with a Browse… button. kind: 'folder' or 'file'."""
    row = QHBoxLayout()
    row.addWidget(field, 1)
    button = QPushButton("Browse…")

    def browse():
        start = str(Path(field.text().strip()).expanduser()) if field.text().strip() else ""
        if kind == "folder":
            chosen = QFileDialog.getExistingDirectory(field, caption, start)
        else:
            chosen, _ = QFileDialog.getOpenFileName(field, caption, str(Path(start).parent) if start else "", filters)
        if chosen:
            field.setText(chosen)

    button.clicked.connect(browse)
    row.addWidget(button)
    return row


class WorkerPanel(QWidget):
    """Runs one worker process, shows its log and progress, and supports Cancel.

    Workers print "@progress CURRENT TOTAL PHASE" lines; these update the bar
    and are not shown in the log.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.process = None
        self.on_finished = None
        self.status = QLabel("Ready")
        self.bar = QProgressBar()
        self.bar.setVisible(False)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setPlaceholderText("Processing output will appear here.")
        self.log.document().setMaximumBlockCount(5000)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.status)
        layout.addWidget(self.bar)
        layout.addWidget(self.log, 1)
        self._pending = ""

    @property
    def running(self):
        return self.process is not None

    def start(self, mode, arguments, running_text="Running…"):
        if self.process is not None:
            return
        self.log.clear()
        self.status.setText(running_text)
        self.bar.setRange(0, 0)
        self.bar.setVisible(True)
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._pending = ""
        p = QProcess(self)
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PYTHONIOENCODING", "utf-8")
        env.insert("PYTHONUNBUFFERED", "1")
        p.setProcessEnvironment(env)
        p.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        p.readyReadStandardOutput.connect(self._read)
        p.errorOccurred.connect(self._error)
        p.finished.connect(self._finished)
        self.process = p
        program, args = tool_command(mode, arguments)
        p.start(program, args)

    def cancel(self):
        if self.process is None:
            return
        self.status.setText("Stopping…")
        self.process.terminate()
        QTimer.singleShot(3000, lambda: self.process and self.process.kill())

    def _read(self):
        if self.process is None:
            return
        text = self._pending + self._decoder.decode(bytes(self.process.readAllStandardOutput()))
        lines = text.replace("\r", "\n").split("\n")
        self._pending = lines.pop()
        shown = []
        for line in lines:
            if line.startswith("@progress "):
                parts = line.split(" ", 3)
                try:
                    current, total = int(parts[1]), int(parts[2])
                    self.bar.setRange(0, max(1, total))
                    self.bar.setValue(current)
                    self.bar.setFormat(f"{parts[3] if len(parts) > 3 else ''}: %v/%m")
                except ValueError:
                    pass
            else:
                shown.append(line)
        if shown:
            self.log.moveCursor(QTextCursor.MoveOperation.End)
            self.log.insertPlainText("\n".join(shown) + "\n")
            self.log.ensureCursorVisible()

    def _error(self, error):
        if error == QProcess.ProcessError.FailedToStart and self.process is not None:
            self.log.appendPlainText(self.process.errorString())
            self._finished(-1, QProcess.ExitStatus.CrashExit)

    def _finished(self, code, status):
        self._read()
        if self._pending:
            self.log.appendPlainText(self._pending)
            self._pending = ""
        ok = code == 0 and status == QProcess.ExitStatus.NormalExit
        self.status.setText("Completed" if ok else f"Stopped (exit code {code}) — see log")
        self.bar.setVisible(False)
        if self.process is not None:
            self.process.deleteLater()
        self.process = None
        if self.on_finished:
            self.on_finished(ok)

    def confirm_close(self, parent):
        """For closeEvent: True when the window may close."""
        if self.process is None:
            return True
        answer = QMessageBox.question(parent, "Still running", "Stop the running work and close the window?")
        if answer == QMessageBox.StandardButton.Yes:
            self.process.kill()
            self.process.waitForFinished(3000)
            return True
        return False


class Relay(QObject):
    """Carries a value from a worker thread to the GUI thread (queued signal)."""

    done = pyqtSignal(object)


def run_in_background(fn, on_done, parent):
    """Call fn() on a daemon thread, then on_done(result) on the GUI thread."""
    relay = Relay(parent)
    relay.done.connect(on_done)
    threading.Thread(target=lambda: relay.done.emit(fn()), daemon=True).start()
    return relay


def line_edit(placeholder=""):
    e = QLineEdit()
    e.setPlaceholderText(placeholder)
    return e
