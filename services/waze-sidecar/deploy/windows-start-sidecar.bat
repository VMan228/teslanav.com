@echo off
:: Waze sidecar startup script for Windows.
:: Starts Edge with remote debugging, then launches the Python sidecar.
:: Run this at startup (e.g. via Task Scheduler at logon).

set SIDECAR_DIR=C:\waze-sidecar
set EDGE_EXE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe

:: Kill any existing Edge/sidecar instances
taskkill /F /IM msedge.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:: Start Edge with remote debugging port (hidden, no first-run wizard)
start "" "%EDGE_EXE%" --remote-debugging-port=9222 --no-first-run --window-position=-32000,-32000
timeout /t 3 /nobreak >nul

:: Set sidecar environment
set BROWSER_CDP_URL=http://127.0.0.1:9222
set BROWSER_PROXY_URL=
set PLAYWRIGHT_HEADLESS=0
set COOKIE_FILE=%SIDECAR_DIR%\data\waze_session.json

:: Start sidecar
cd /d %SIDECAR_DIR%
py -3.12 -m uvicorn app:app --host 0.0.0.0 --port 8001
