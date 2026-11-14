@echo off
rem Keep environment-variable changes local to this installer process.
setlocal
rem Define the installation directory and a unique temporary archive path.
set "INSTALL_DIR=%LOCALAPPDATA%\DriftCorrect"
set "INSTALL_ZIP=%TEMP%\DriftCorrect-%RANDOM%-%RANDOM%.zip"

rem Download the selected DriftCorrect source branch as a ZIP archive.
curl -fL https://github.com/AryaDesai/DriftCorrect/archive/refs/heads/z-correction.zip -o "%INSTALL_ZIP%"
if errorlevel 1 exit /b 1
rem Create the installation directory and extract the archive into it.
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
tar -xf "%INSTALL_ZIP%" -C "%INSTALL_DIR%" --strip-components 1
if errorlevel 1 exit /b 1
rem Remove the temporary archive after extraction.
del "%INSTALL_ZIP%"

rem Create a private Python environment for bootstrapping uv.
if not exist "%INSTALL_DIR%\.uv-bootstrap\Scripts\python.exe" (
    python -m venv "%INSTALL_DIR%\.uv-bootstrap"
    if errorlevel 1 exit /b 1
)
rem Install uv in the private bootstrap environment.
"%INSTALL_DIR%\.uv-bootstrap\Scripts\python.exe" -m pip install uv
if errorlevel 1 exit /b 1
rem Place the project environment inside the DriftCorrect installation directory.
set "UV_PROJECT_ENVIRONMENT=%INSTALL_DIR%\.venv"
rem Install the project environment and its dependencies.
"%INSTALL_DIR%\.uv-bootstrap\Scripts\python.exe" "%INSTALL_DIR%\scripts\install_windows_environment.py"
if errorlevel 1 exit /b 1

rem Write a persistent launcher that runs DriftCorrect with the project Python.
>"%INSTALL_DIR%\driftcorrect.bat" echo @echo off
>>"%INSTALL_DIR%\driftcorrect.bat" echo "%%~dp0.venv\Scripts\python.exe" "%%~dp0DriftCorrectPy_windows\drift_correct.py" %%*
rem Register a short-lived command alias for the current command prompt.
doskey driftcorrect=call "%INSTALL_DIR%\driftcorrect.bat" $*
rem Create a desktop shortcut pointing to the persistent launcher.
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\DriftCorrect.lnk'); $s.TargetPath=$env:INSTALL_DIR+'\driftcorrect.bat'; $s.WorkingDirectory=$env:INSTALL_DIR; $s.Save()"
if errorlevel 1 exit /b 1
rem Report successful installation and restore the caller's environment.
echo Installed. Type driftcorrect or use the DriftCorrect desktop shortcut.
endlocal
