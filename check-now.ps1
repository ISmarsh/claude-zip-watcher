# One-time check for pending zip files in the watch folder.
# Use when you don't want to wait for the next poll cycle.
& (Join-Path $PSScriptRoot "watch-and-unzip.ps1") -CheckNow
