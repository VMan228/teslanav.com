# Waze sidecar runner for Windows.
# Run this after windows-setup.ps1 to start the Playwright sidecar.
# The SSH tunnel (port 8001) must be active so the VPS can reach this service.
#
# Prerequisites:
#   pip install playwright uvicorn fastapi
#   playwright install chromium
#
# Usage:
#   .\windows-run.ps1
#   .\windows-run.ps1 -CookieFile "C:\path\to\waze_session.json"

param(
    [string]$CookieFile = "$PSScriptRoot\..\data\waze_session.json",
    [string]$Port = "8001"
)

$ErrorActionPreference = "Stop"

$sidecarDir = (Resolve-Path "$PSScriptRoot\..").Path

if (-not (Test-Path $CookieFile)) {
    Write-Host "WARN: Cookie file not found at $CookieFile" -ForegroundColor Yellow
    Write-Host "      Sidecar will return 503 until cookies are provided." -ForegroundColor Yellow
}

$env:COOKIE_FILE        = $CookieFile
$env:BROWSER_PROXY_URL  = ""
$env:PLAYWRIGHT_HEADLESS = "0"

Write-Host ""
Write-Host "Starting Waze sidecar on port $Port..." -ForegroundColor Cyan
Write-Host "  Sidecar dir : $sidecarDir"
Write-Host "  Cookie file : $env:COOKIE_FILE"
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

Set-Location $sidecarDir
python -m uvicorn app:app --host 127.0.0.1 --port $Port
