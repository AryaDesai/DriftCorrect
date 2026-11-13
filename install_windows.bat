setlocal
set "INSTALL_DIR=%LOCALAPPDATA%\DriftCorrect"
set "INSTALL_ZIP=%TEMP%\DriftCorrect-%RANDOM%-%RANDOM%.zip"

curl -fL https://github.com/AryaDesai/DriftCorrect/archive/refs/heads/z-correction.zip -o "%INSTALL_ZIP%"
if errorlevel 1 exit /b 1
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
tar -xf "%INSTALL_ZIP%" -C "%INSTALL_DIR%" --strip-components 1
if errorlevel 1 exit /b 1
del "%INSTALL_ZIP%"

rem Bootstrap uv privately, even when Anaconda is installed for all users.
if not exist "%INSTALL_DIR%\.uv-bootstrap\Scripts\python.exe" (
    python -m venv "%INSTALL_DIR%\.uv-bootstrap"
    if errorlevel 1 exit /b 1
)
"%INSTALL_DIR%\.uv-bootstrap\Scripts\python.exe" -m pip install uv
if errorlevel 1 exit /b 1
set "UV_PROJECT_ENVIRONMENT=%INSTALL_DIR%\.venv"
"%INSTALL_DIR%\.uv-bootstrap\Scripts\python.exe" "%INSTALL_DIR%\scripts\install_windows_environment.py"
if errorlevel 1 exit /b 1

rem Write a persistent launcher and a short command for this prompt.
>"%INSTALL_DIR%\driftcorrect.bat" echo @echo off
>>"%INSTALL_DIR%\driftcorrect.bat" echo "%%~dp0.venv\Scripts\python.exe" "%%~dp0DriftCorrectPy_windows\drift_correct.py" %%*
doskey driftcorrect=call "%INSTALL_DIR%\driftcorrect.bat" $*
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\DriftCorrect.lnk'); $s.TargetPath=$env:INSTALL_DIR+'\driftcorrect.bat'; $s.WorkingDirectory=$env:INSTALL_DIR; $s.Save()"
if errorlevel 1 exit /b 1
echo Installed. Type driftcorrect or use the DriftCorrect desktop shortcut.
endlocal
