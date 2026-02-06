# ============================================================
# Watch-And-Unzip.ps1
# Monitors a folder for new .zip files, extracts them to a
# destination folder, and deletes the original .zip
#
# Usage:
#   .\watch-and-unzip.ps1              # Run watcher (default)
#   .\watch-and-unzip.ps1 -CheckNow   # One-time poll, then exit
#   .\watch-and-unzip.ps1 -PollInterval 300  # Custom poll (seconds)
# ============================================================
param(
    [int]$PollInterval = 600,
    [switch]$CheckNow
)

# --- CONFIGURATION -------------------------------------------
# Watch this folder for incoming .zip files
$WatchFolder = "G:\My Drive\Claude Files"

# Extract contents here
$DestinationFolder = "C:\Dev"

# Log file location
$LogFile = Join-Path $PSScriptRoot "unzip-log.txt"
# -------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

# Create folders if they don't exist
if (-not (Test-Path $WatchFolder)) {
    New-Item -ItemType Directory -Path $WatchFolder -Force | Out-Null
    Write-Log "Created watch folder: $WatchFolder"
}
if (-not (Test-Path $DestinationFolder)) {
    New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    Write-Log "Created destination folder: $DestinationFolder"
}

# Process a zip file: extract then delete
function Process-ZipFile {
    param([string]$FilePath)

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $extractTo = Join-Path $DestinationFolder $fileName

    # Wait for the file to finish writing (Google Drive sync)
    $retries = 0
    while ($retries -lt 30) {
        try {
            $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
            $stream.Close()
            break
        } catch {
            Start-Sleep -Seconds 2
            $retries++
        }
    }

    if ($retries -ge 30) {
        Write-Log "TIMEOUT: Could not access $FilePath after 60 seconds. Skipping."
        return
    }

    try {
        # Handle duplicate folder names
        if (Test-Path $extractTo) {
            $counter = 2
            while (Test-Path "${extractTo}_$counter") { $counter++ }
            $extractTo = "${extractTo}_$counter"
        }

        New-Item -ItemType Directory -Path $extractTo -Force | Out-Null
        Expand-Archive -Path $FilePath -DestinationPath $extractTo -Force
        Write-Log "EXTRACTED: $FilePath -> $extractTo"

        Remove-Item -Path $FilePath -Force
        Write-Log "DELETED: $FilePath"
    } catch {
        Write-Log "ERROR processing $FilePath : $_"
    }
}

# --- Process any existing .zip files on startup --------------
$existing = Get-ChildItem -Path $WatchFolder -Filter "*.zip" -File
foreach ($file in $existing) {
    Write-Log "Found existing zip: $($file.FullName)"
    Process-ZipFile -FilePath $file.FullName
}

# --- CheckNow mode: one-time poll, then exit -----------------
if ($CheckNow) {
    if (-not $existing) {
        Write-Log "CHECK: No zip files found."
    }
    return
}

# --- Set up FileSystemWatcher --------------------------------
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $WatchFolder
$watcher.Filter = "*.zip"
$watcher.IncludeSubdirectories = $false
$watcher.InternalBufferSize = 65536
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
$watcher.EnableRaisingEvents = $true

$action = {
    $filePath = $Event.SourceEventArgs.FullPath
    $changeType = $Event.SourceEventArgs.ChangeType
    Write-Log "DETECTED ($changeType): $filePath"

    # Small delay to let Google Drive finish syncing
    Start-Sleep -Seconds 3
    Process-ZipFile -FilePath $filePath
}

Register-ObjectEvent $watcher "Created" -Action $action | Out-Null
Register-ObjectEvent $watcher "Renamed" -Action $action | Out-Null
Register-ObjectEvent $watcher "Error" -Action {
    Write-Log "FSW buffer overflow - running immediate poll"
    $missed = Get-ChildItem -Path $WatchFolder -Filter "*.zip" -File -ErrorAction SilentlyContinue
    foreach ($file in $missed) {
        Write-Log "RECOVERY: Found $($file.FullName)"
        Process-ZipFile -FilePath $file.FullName
    }
} | Out-Null

Write-Log "=== Watcher started ==="
Write-Log "Watching: $WatchFolder"
Write-Log "Extracting to: $DestinationFolder"
Write-Log "Press Ctrl+C to stop."

# Keep the script running with polling fallback
# FSW works most of the time on Google Drive but can silently miss events
# on virtual filesystems. Poll periodically as a safety net.
# Use -CheckNow for an immediate one-off check.
try {
    while ($true) {
        Start-Sleep -Seconds $PollInterval
        $missed = Get-ChildItem -Path $WatchFolder -Filter "*.zip" -File -ErrorAction SilentlyContinue
        foreach ($file in $missed) {
            Write-Log "POLL: Found $($file.FullName)"
            Process-ZipFile -FilePath $file.FullName
        }
    }
} finally {
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    Write-Log "=== Watcher stopped ==="
}
