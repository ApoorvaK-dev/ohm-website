# ─────────────────────────────────────────────────────────────────
# Ohm — Windows PowerShell Installer
# Supports: Windows 10 / 11 (PowerShell 5.1+)
# Source:   https://apoorvak-dev.github.io/ohm-website/install.ps1
# Usage:    irm https://apoorvak-dev.github.io/ohm-website/install.ps1 | iex
# ─────────────────────────────────────────────────────────────────
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# ── Colours ───────────────────────────────────────────────────────
function Write-Ok($msg)   { Write-Host "  $([char]0x2713)  $msg" -ForegroundColor Green }
function Write-Log($msg)  { Write-Host "  $([char]0x25B8)  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "  !  $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  X  $msg" -ForegroundColor Red; exit 1 }

# ── Banner ────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  Ohm Installer for Windows" -ForegroundColor White
Write-Host ""

# ── Admin check ───────────────────────────────────────────────────
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Write-Warn "Not running as Administrator."
  Write-Warn "The daemon will be installed as a user-level scheduled task instead of a Windows Service."
  Write-Warn "For Windows Service installation, re-run PowerShell as Administrator."
  Write-Host ""
  $UseTask = $true
} else {
  $UseTask = $false
}

# ── Detect architecture ───────────────────────────────────────────
$Arch = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
switch ($Arch) {
  "AMD64"   { $Platform = "windows-x64" }
  "ARM64"   { $Platform = "windows-arm64" }
  default   { Write-Fail "Unsupported architecture: $Arch" }
}
Write-Log "Platform: $Platform"

# ── Paths ─────────────────────────────────────────────────────────
$InstallDir = "$env:LOCALAPPDATA\ohm\bin"
$DataDir    = "$env:APPDATA\ohm"
$DaemonExe  = "$InstallDir\ohm-daemon.exe"
$LogDir     = "$DataDir\logs"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir    | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir     | Out-Null
New-Item -ItemType Directory -Force -Path "$DataDir\users" | Out-Null

# ── Download binary ───────────────────────────────────────────────
$Repo        = "https://github.com/ApoorvaK-dev/ohm"
$DownloadUrl = "$Repo/releases/latest/download/ohm-daemon-$Platform.exe"

Write-Log "Downloading ohm-daemon ($Platform)..."
Write-Log "URL: $DownloadUrl"

try {
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  $ProgressPreference = 'SilentlyContinue'  # speeds up Invoke-WebRequest significantly
  Invoke-WebRequest -Uri $DownloadUrl -OutFile $DaemonExe -UseBasicParsing
} catch {
  Write-Fail "Download failed: $_`nVisit $Repo/releases to download manually."
}

if (-not (Test-Path $DaemonExe) -or (Get-Item $DaemonExe).Length -eq 0) {
  Write-Fail "Downloaded file is empty or missing. The release binary may not exist yet."
}

Write-Ok "ohm-daemon.exe → $DaemonExe"

# ── Write base config ─────────────────────────────────────────────
$ConfigFile = "$DataDir\config.json"
if (-not (Test-Path $ConfigFile)) {
  $Config = @{
    version      = "0.1.0"
    port         = 47832
    data_dir     = $DataDir
    log_level    = "info"
    installed_at = (Get-Date -Format "o")
  } | ConvertTo-Json -Depth 3
  $Config | Set-Content -Path $ConfigFile -Encoding UTF8
}
Write-Ok "Config: $ConfigFile"

# ── Add to PATH ───────────────────────────────────────────────────
$UserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$InstallDir*") {
  [System.Environment]::SetEnvironmentVariable(
    "Path", "$InstallDir;$UserPath", "User")
  $env:Path = "$InstallDir;$env:Path"
  Write-Ok "Added to PATH (user scope)"
}

# ── Register service / task ───────────────────────────────────────
if ($UseTask) {
  # Scheduled Task (no admin required)
  $TaskName = "OhmDaemon"
  $Action   = New-ScheduledTaskAction -Execute $DaemonExe -Argument "start"
  $Trigger  = New-ScheduledTaskTrigger -AtLogOn
  $Settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
  $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited

  # Remove existing task if present
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

  Register-ScheduledTask -TaskName $TaskName -Action $Action `
    -Trigger $Trigger -Settings $Settings -Principal $Principal | Out-Null

  # Start immediately
  Start-ScheduledTask -TaskName $TaskName
  Write-Ok "Scheduled Task '$TaskName' registered — auto-starts on login"

} else {
  # Windows Service (requires admin)
  $ServiceName = "OhmDaemon"

  # Stop + remove existing service
  $ExistingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($ExistingSvc) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
  }

  # Create new service
  New-Service `
    -Name        $ServiceName `
    -BinaryPathName "$DaemonExe start" `
    -DisplayName "Ohm Daemon" `
    -Description "Ohm agentic AI daemon — runs in background, never interacted with directly" `
    -StartupType Automatic | Out-Null

  Start-Service -Name $ServiceName
  Write-Ok "Windows Service '$ServiceName' registered — auto-starts on login"
}

# ── Done ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Ohm daemon installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Open the Ohm app and enter your pairing code."
Write-Host "  The daemon shows a 6-digit code on first start."
Write-Host ""
Write-Host "  Daemon exe:  $DaemonExe"
Write-Host "  Data dir:    $DataDir"
Write-Host "  Logs:        $LogDir"
Write-Host ""
