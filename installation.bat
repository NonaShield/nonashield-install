@echo off
:: =============================================================================
:: PayShield — Windows Quick-Start Launcher
:: Delegates to the full PowerShell installer (install-windows.ps1)
:: =============================================================================
cd /d "%~dp0"

echo.
echo  PayShield — Windows Installer
echo  ==============================
echo.
echo  Launching install-windows.ps1 ...
echo.

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" %*

if ERRORLEVEL 1 (
    echo.
    echo  [ERROR] Installation failed. See output above.
    pause
    exit /b 1
)
