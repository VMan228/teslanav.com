#Requires -RunAsAdministrator
# Windows setup for Waze sidecar residential proxy.
# Run in PowerShell as Administrator:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\windows-setup.ps1

param(
    [Parameter(Mandatory)]
    [string]$VpsPublicKey,      # Contents of cat ~/.ssh/id_ed25519.pub on the VPS

    [Parameter(Mandatory)]
    [string]$VpsHost            # VPS IP or hostname (e.g. nav.example.com)
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    WARN: $msg" -ForegroundColor Yellow }

# ── 1. OpenSSH Server ─────────────────────────────────────────────────────────
Write-Step "Installing OpenSSH Server..."
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($cap.State -ne "Installed") {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-Ok "OpenSSH Server installed"
} else {
    Write-Ok "OpenSSH Server already installed"
}
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Write-Ok "sshd running and set to auto-start"

# ── 2. Authorized key ─────────────────────────────────────────────────────────
Write-Step "Adding VPS public key to authorized_keys..."

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    $keyFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    Write-Warn "Administrator account detected — using $keyFile"
} else {
    $keyFile = "$env:USERPROFILE\.ssh\authorized_keys"
    New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
}

# Avoid duplicates
$existing = if (Test-Path $keyFile) { Get-Content $keyFile } else { @() }
if ($existing -contains $VpsPublicKey) {
    Write-Ok "Key already present — skipping"
} else {
    Add-Content $keyFile $VpsPublicKey
    Write-Ok "Key added to $keyFile"
}

if ($isAdmin) {
    icacls $keyFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
    Write-Ok "Permissions set on administrators_authorized_keys"
}

# ── 3. Reverse SSH tunnel scheduled task ──────────────────────────────────────
Write-Step "Creating scheduled task for reverse SSH tunnel..."

$taskName  = "WazeSidecarSSHTunnel"
$sshArgs   = "-N -R 2222:localhost:22 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new $VpsHost"

# Remove old task if exists
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action  = New-ScheduledTaskAction -Execute "ssh.exe" -Argument $sshArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask `
    -TaskName  $taskName `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal | Out-Null

Write-Ok "Scheduled task '$taskName' created (runs at logon, restarts on failure)"

# Start it now without waiting for next logon
Start-ScheduledTask -TaskName $taskName
Write-Ok "Tunnel started — VPS port 2222 now forwards to this machine's SSH"

# ── 4. Firewall ───────────────────────────────────────────────────────────────
Write-Step "Ensuring Windows Firewall allows inbound SSH..."
$rule = Get-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Ok "Firewall rule added"
} else {
    Write-Ok "Firewall rule already exists"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host @"

Setup complete.

Next steps on the VPS:
  1. Wait ~10 seconds for the tunnel to establish, then verify:
       ssh -p 2222 $env:USERNAME@127.0.0.1 exit

  2. Install the SOCKS5 service:
       sudo make setup-socks5 WINDOWS_USER=$env:USERNAME

  3. Verify the residential exit IP:
       curl --proxy socks5://127.0.0.1:1080 -s https://cloudflare.com/cdn-cgi/trace | grep ip=

  4. Enable in sidecar:
       echo 'BROWSER_PROXY_URL=socks5://127.0.0.1:1080' | sudo tee -a /opt/waze-sidecar/.env
       sudo make restart-sidecar

"@ -ForegroundColor Green
