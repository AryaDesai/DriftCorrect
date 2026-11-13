@echo off
setlocal
if not exist "%~dp0.venv\Scripts\python.exe" (
    echo Run install_windows.bat from Anaconda Prompt first.
    exit /b 1
)
"%~dp0.venv\Scripts\python.exe" "%~dp0DriftCorrectPy_windows\drift_correct.py" %*
exit /b %errorlevel%
