@echo off
:: ─────────────────────────────────────────────────────────────────
:: Ohm — Windows CMD Installer (Fallback)
:: Requires: Windows 10+ with curl.exe (built-in since 1803)
:: Usage: curl -fsSL https://apoorvak-dev.github.io/ohm-website/install.cmd -o %TEMP%\ohm-install.cmd && %TEMP%\ohm-install.cmd
:: ─────────────────────────────────────────────────────────────────
setlocal enabledelayedexpansion

echo.
echo   Ohm Installer for Windows (CMD)
echo.

:: ── Check PowerShell first (preferred) ───────────────────────────
where powershell >nul 2>&1
if %errorlevel% equ 0 (
  echo   PowerShell detected. Using PowerShell installer...
  echo.
  powershell -ExecutionPolicy Bypass -Command ^
    "irm https://apoorvak-dev.github.io/ohm-website/install.ps1 | iex"
  goto :done
)

:: ── PowerShell not available — fallback to direct curl download ──
echo   PowerShell not found. Using direct download...
echo.

:: Detect architecture
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
  set PLATFORM=windows-x64
) else if "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
  set PLATFORM=windows-arm64
) else (
  echo   ERROR: Unsupported architecture: %PROCESSOR_ARCHITECTURE%
  exit /b 1
)

:: Paths
set INSTALL_DIR=%LOCALAPPDATA%\ohm\bin
set DATA_DIR=%APPDATA%\ohm
set DAEMON_EXE=%INSTALL_DIR%\ohm-daemon.exe

:: Create dirs
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if not exist "%DATA_DIR%"    mkdir "%DATA_DIR%"
if not exist "%DATA_DIR%\logs"  mkdir "%DATA_DIR%\logs"
if not exist "%DATA_DIR%\users" mkdir "%DATA_DIR%\users"

:: Download
set DOWNLOAD_URL=https://github.com/ApoorvaK-dev/ohm/releases/latest/download/ohm-daemon-%PLATFORM%.exe
echo   Downloading ohm-daemon (%PLATFORM%)...
echo   URL: %DOWNLOAD_URL%
curl -fsSL "%DOWNLOAD_URL%" -o "%DAEMON_EXE%"

if not exist "%DAEMON_EXE%" (
  echo   ERROR: Download failed.
  echo   Visit https://github.com/ApoorvaK-dev/ohm/releases to download manually.
  exit /b 1
)

echo   Downloaded: %DAEMON_EXE%

:: Add to PATH (user scope via reg)
for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set CURRENT_PATH=%%B
echo %CURRENT_PATH% | find /i "%INSTALL_DIR%" >nul
if %errorlevel% neq 0 (
  reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%INSTALL_DIR%;%CURRENT_PATH%" /f >nul
  echo   Added %INSTALL_DIR% to PATH
)

:: Register scheduled task (no admin needed)
set TASK_NAME=OhmDaemon
schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
schtasks /create /tn "%TASK_NAME%" /tr "\"%DAEMON_EXE%\" start" ^
  /sc onlogon /ru %USERNAME% /f >nul
schtasks /run /tn "%TASK_NAME%" >nul
echo   Scheduled task registered: %TASK_NAME%

:done
echo.
echo   Ohm daemon installed.
echo   Open the Ohm app and enter your 6-digit pairing code.
echo.
endlocal
