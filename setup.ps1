# ============================================================
# setup.ps1
# One-script setup for Claude Zip Watcher:
#   0. Verify Python + watchdog
#   1. Install Google Drive for Desktop (stream mode)
#   2. Configure drive letter and watch folder
#   3. Register scheduled task for the watcher (pythonw.exe)
#
# Detects completed steps and skips them. Safe to re-run.
#
# Run as administrator:
#   powershell -ExecutionPolicy Bypass -File setup.ps1
# ============================================================

# --- CONFIGURATION -------------------------------------------
$DriveLetter = "G"
$WatchFolderName = "Claude Files"
$WatcherScript = Join-Path $PSScriptRoot "watcher.py"
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$TaskName = "Claude Zip Watcher"
$DestinationFolder = "C:\Dev"
# -------------------------------------------------------------

$DrivefsConfigPath = "$env:LOCALAPPDATA\Google\DriveFS"
$InstallerUrl = "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe"
$InstallerPath = "$env:TEMP\GoogleDriveSetup.exe"
$RegistryPath = "HKLM:\SOFTWARE\Google\DriveFS"
$MyDrivePath = "${DriveLetter}:\My Drive"
$WatchPath = Join-Path $MyDrivePath $WatchFolderName

# --- Require admin -------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as administrator', then re-run this script."
    exit 1
}

# --- Detect current state ------------------------------------
# --- Verify Python + watchdog --------------------------------
$PythonwExe = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
$PythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $PythonwExe -or -not $PythonExe) {
    Write-Host "ERROR: python.exe / pythonw.exe not found on PATH." -ForegroundColor Red
    Write-Host "Install Python 3.11+ from https://www.python.org/downloads/"
    exit 1
}
# Check watchdog is installed
& $PythonExe -c "import watchdog" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Installing watchdog..." -ForegroundColor Cyan
    & $PythonExe -m pip install watchdog
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to install watchdog." -ForegroundColor Red
        exit 1
    }
    Write-Host "  watchdog installed." -ForegroundColor Green
}

$driveInstalled = (Get-ItemProperty "HKLM:\SOFTWARE\Google\Drive" -ErrorAction SilentlyContinue) -or (Test-Path $DrivefsConfigPath)
$regMountPoint = (Get-ItemProperty -Path $RegistryPath -Name "DefaultMountPoint" -ErrorAction SilentlyContinue).DefaultMountPoint
$registryConfigured = $regMountPoint -eq $DriveLetter
$driveMounted = Test-Path $MyDrivePath
$watchFolderExists = Test-Path $WatchPath
$taskExists = $null -ne (schtasks /query /tn $TaskName 2>$null)

Write-Host ""
Write-Host "=== Claude Zip Watcher - Setup ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Current state:" -ForegroundColor Cyan

function Show-Status {
    param([string]$Label, [bool]$Done)
    $icon = if ($Done) { "[done]" } else { "[    ]" }
    $color = if ($Done) { "Green" } else { "DarkGray" }
    Write-Host "    $icon $Label" -ForegroundColor $color
}

Show-Status "Google Drive installed" $driveInstalled
if ($regMountPoint -and -not $registryConfigured) {
    Write-Host "    [    ] Registry configured (currently ${regMountPoint}:, expects ${DriveLetter}:)" -ForegroundColor DarkGray
} else {
    Show-Status "Registry configured (${DriveLetter}:)" $registryConfigured
}
Show-Status "Drive mounted at ${DriveLetter}:" $driveMounted
Show-Status "Watch folder ($WatchFolderName)" $watchFolderExists
Show-Status "Scheduled task" $taskExists

$allDone = $driveInstalled -and $registryConfigured -and $driveMounted -and $watchFolderExists -and $taskExists

if ($allDone) {
    Write-Host ""
    Write-Host "  Everything is already set up!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  1. Exit" -ForegroundColor Cyan
    Write-Host "  2. Re-run all steps anyway" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Enter 1 or 2"
    if ($choice -ne "2") {
        exit 0
    }
    Write-Host ""
}

# --- Destination folder prompt --------------------------------
Write-Host ""
Write-Host "  Extract destination: $DestinationFolder" -ForegroundColor Cyan
$inputDest = Read-Host "  Change? (Enter to keep, or type new path)"
if ($inputDest) { $DestinationFolder = $inputDest }

$warnings = @()
$completed = @()

# =============================================================
# STEP 1: Google Drive for Desktop
# =============================================================
Write-Host ""
Write-Host "[1/3] Google Drive for Desktop" -ForegroundColor Cyan
Write-Host "---------------------------------------------"

if ($driveInstalled) {
    Write-Host "  Already installed." -ForegroundColor Green

    # Check for mirror mode risk on existing installs
    $hasExistingConfig = Test-Path $DrivefsConfigPath
    if ($hasExistingConfig) {
        Write-Host ""
        Write-Host "  NOTE: Existing config found at $DrivefsConfigPath" -ForegroundColor Yellow
        Write-Host "  If this was previously set to mirror mode, stream mode must be" -ForegroundColor Yellow
        Write-Host "  verified manually (no registry key exists to force it)." -ForegroundColor Yellow
        Write-Host "    Gear icon > Preferences > Google Drive tab > 'Stream files'" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No installation found."
    Write-Host ""
    Write-Host "  1. Download and install Google Drive for Desktop" -ForegroundColor Cyan
    Write-Host "  2. Skip (I'll install it myself)" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Enter 1 or 2"

    if ($choice -eq "1") {
        Write-Host "  Downloading Google Drive for Desktop..."
        try {
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing
        } catch {
            Write-Host "  ERROR: Failed to download installer: $_" -ForegroundColor Red
            Write-Host "  Download manually from https://www.google.com/drive/download/"
            Write-Host "  Then re-run this script."
            exit 1
        }

        Write-Host "  Installing silently (this may take a minute)..."
        $process = Start-Process -FilePath $InstallerPath `
            -ArgumentList "--silent", "--skip_launch_new" `
            -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-Host "  ERROR: Installer exited with code $($process.ExitCode)" -ForegroundColor Red
            exit 1
        }

        Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
        Write-Host "  Installed." -ForegroundColor Green
        $driveInstalled = $true
    } else {
        Write-Host "  Skipped. Re-run this script after installing Google Drive."
        exit 0
    }
}
$completed += "Google Drive installed"

# =============================================================
# STEP 1b: Registry configuration
# =============================================================
if ($registryConfigured) {
    Write-Host "  Registry already configured (${DriveLetter}:)." -ForegroundColor Green
} elseif ($regMountPoint) {
    # Registry exists but with a different drive letter
    Write-Host ""
    Write-Host "  Registry has drive letter ${regMountPoint}: but setup expects ${DriveLetter}:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Update registry to ${DriveLetter}: (matches setup config)" -ForegroundColor Cyan
    Write-Host "  2. Keep ${regMountPoint}: and update watcher script to match" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Enter 1 or 2"

    if ($choice -eq "2") {
        # Adopt the existing drive letter
        $DriveLetter = $regMountPoint
        $MyDrivePath = "${DriveLetter}:\My Drive"
        $WatchPath = Join-Path $MyDrivePath $WatchFolderName
        $driveMounted = Test-Path $MyDrivePath
        $watchFolderExists = Test-Path $WatchPath
        Write-Host "  Keeping ${DriveLetter}:." -ForegroundColor Green
    } else {
        New-ItemProperty -Path $RegistryPath -Name "DefaultMountPoint" -Value $DriveLetter -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegistryPath -Name "AutoStartOnLogin" -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Host "  Registry updated to ${DriveLetter}:" -ForegroundColor Green
        Write-Host "  Auto-start on login: enabled" -ForegroundColor Green
        Write-Host "  NOTE: Restart Google Drive for the new letter to take effect." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Configuring registry..."
    New-Item -Path $RegistryPath -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name "DefaultMountPoint" -Value $DriveLetter -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name "AutoStartOnLogin" -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "  Drive letter set to ${DriveLetter}:" -ForegroundColor Green
    Write-Host "  Auto-start on login: enabled" -ForegroundColor Green
}
$completed += "Registry configured (${DriveLetter}:)"

# =============================================================
# STEP 2: Sign in and create watch folder
# =============================================================
Write-Host ""
Write-Host "[2/3] Watch Folder" -ForegroundColor Cyan
Write-Host "---------------------------------------------"

if ($watchFolderExists) {
    Write-Host "  Already exists: $WatchPath" -ForegroundColor Green
} elseif ($driveMounted) {
    # Drive is mounted but folder doesn't exist yet
    New-Item -Path $WatchPath -ItemType Directory -Force | Out-Null
    Write-Host "  Created: $WatchPath" -ForegroundColor Green
} else {
    # Drive not mounted -- need sign-in
    Write-Host ""
    Write-Host "  Google Drive is not mounted at ${DriveLetter}: yet." -ForegroundColor Yellow
    Write-Host "  Please sign in now:" -ForegroundColor Cyan
    Write-Host "    1. Look for the Drive icon in the system tray"
    Write-Host "    2. Click it and sign in with your Google account"
    Write-Host "    3. IMPORTANT: Verify stream mode is active:" -ForegroundColor Yellow
    Write-Host "       Gear > Preferences > Google Drive tab" -ForegroundColor Yellow
    Write-Host "       Ensure 'Stream files' is selected" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Wait for sign-in (up to 5 minutes)" -ForegroundColor Cyan
    Write-Host "  2. Skip -- I'll sign in later and re-run this script" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Enter 1 or 2"

    if ($choice -eq "1") {
        Write-Host "  Waiting for ${MyDrivePath} to appear..."
        $maxWait = 300
        $waited = 0

        while (-not (Test-Path $MyDrivePath) -and $waited -lt $maxWait) {
            Start-Sleep -Seconds 5
            $waited += 5
            if ($waited % 30 -eq 0) {
                Write-Host "  Still waiting... ($waited seconds)"
            }
        }

        if (-not (Test-Path $MyDrivePath)) {
            Write-Host ""
            Write-Host "  Timed out after $maxWait seconds." -ForegroundColor Yellow
            Write-Host "  Re-run this script after signing in -- it will pick up where it left off."
            exit 1
        }

        New-Item -Path $WatchPath -ItemType Directory -Force | Out-Null
        Write-Host "  Created: $WatchPath" -ForegroundColor Green
    } else {
        Write-Host "  Skipped. Re-run this script after signing in."
        Write-Host "  Continuing to scheduled task setup..."
        $warnings += "Google Drive sign-in skipped - watch folder not created"
    }
}

if (Test-Path $WatchPath) {
    $completed += "Watch folder ($WatchFolderName)"
}

# =============================================================
# STEP 3: Scheduled task
# =============================================================
Write-Host ""
Write-Host "[3/3] Scheduled Task" -ForegroundColor Cyan
Write-Host "---------------------------------------------"

if (-not (Test-Path $WatcherScript)) {
    Write-Host "  ERROR: Watcher script not found at $WatcherScript" -ForegroundColor Red
    exit 1
}

# Build task configuration
# pythonw.exe is a GUI-subsystem executable -- Windows never creates a console
# window for it, eliminating the brief flash that powershell.exe -WindowStyle Hidden causes.
$taskAction = New-ScheduledTaskAction `
    -Execute "`"$PythonwExe`"" `
    -Argument "`"$WatcherScript`""

$taskTrigger = New-ScheduledTaskTrigger -AtLogon
# Re-launch every 30 min if process died; IgnoreNew prevents duplicates
$taskTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At "00:00" `
    -RepetitionInterval (New-TimeSpan -Minutes 30)).Repetition

$taskSettings = New-ScheduledTaskSettingsSet `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([System.TimeSpan]::Zero) `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -MultipleInstances IgnoreNew

function Register-WatcherTask {
    try {
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $taskAction `
            -Trigger $taskTrigger `
            -Settings $taskSettings `
            -RunLevel Limited `
            -Force | Out-Null
        return $true
    } catch {
        Write-Host "  ERROR: Failed to create scheduled task: $_" -ForegroundColor Red
        return $false
    }
}

if ($taskExists) {
    Write-Host "  Task '$TaskName' already exists." -ForegroundColor Green
    Write-Host ""
    Write-Host "  1. Keep existing task" -ForegroundColor Cyan
    Write-Host "  2. Replace it (use if watcher script moved)" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Enter 1 or 2"
    if ($choice -ne "2") {
        Write-Host "  Kept existing task." -ForegroundColor Green
    } else {
        if (Register-WatcherTask) {
            Write-Host "  Replaced." -ForegroundColor Green
        } else { exit 1 }
    }
} else {
    if (Register-WatcherTask) {
        Write-Host "  Scheduled task registered." -ForegroundColor Green
        Write-Host "  Runs at login: $WatcherScript"
    } else { exit 1 }
}
$completed += "Scheduled task"

# =============================================================
# Update config.json with current settings
# =============================================================
if (Test-Path $ConfigFile) {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $changed = $false
    if ($config.watch_folder -ne $WatchPath) {
        $config.watch_folder = $WatchPath
        $changed = $true
    }
    if ($config.destination_folder -ne $DestinationFolder) {
        $config.destination_folder = $DestinationFolder
        $changed = $true
    }
    $todoFile = Join-Path $DestinationFolder "todo.md"
    if ($config.todo_file -ne $todoFile) {
        $config.todo_file = $todoFile
        $changed = $true
    }
    if ($changed) {
        $config | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
        Write-Host ""
        Write-Host "  Updated config.json" -ForegroundColor Green
    }
}

# =============================================================
# Summary
# =============================================================
Write-Host ""
$summaryColor = if ($warnings.Count -eq 0) { "Green" } else { "Yellow" }
Write-Host "============================================" -ForegroundColor $summaryColor

if ($warnings.Count -eq 0) {
    Write-Host "  Setup complete!" -ForegroundColor Green
} else {
    Write-Host "  Setup partially complete." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Completed:" -ForegroundColor Cyan
foreach ($step in $completed) {
    Write-Host "    [done] $step" -ForegroundColor Green
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "  Remaining:" -ForegroundColor Yellow
    foreach ($w in $warnings) {
        Write-Host "    ! $w" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Re-run this script to complete remaining steps." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Google Drive:  ${DriveLetter}:" -ForegroundColor Cyan
Write-Host "  Watch folder:  $WatchPath" -ForegroundColor Cyan
Write-Host "  Extracts to:   $DestinationFolder" -ForegroundColor Cyan
Write-Host "  Watcher:       runs at login, auto-restarts, 30-min heartbeat" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To start the watcher now:" -ForegroundColor Cyan
Write-Host "    pythonw.exe `"$WatcherScript`""
Write-Host "============================================" -ForegroundColor $summaryColor
