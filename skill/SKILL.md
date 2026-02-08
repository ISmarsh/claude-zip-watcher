---
name: unpack-gdrive-projects
description: Manage the Google Drive zip watcher - check for pending zips, view logs, verify watcher status
user-invocable: true
allowed-tools:
  - Bash(python *)
  - Bash(powershell *)
  - Read
argument-hint: "[check|status|log|config]"
---

# Unpack Google Drive Projects

Manage the Claude Zip Watcher that monitors Google Drive for uploaded zip files and extracts them to the dev workspace.

Find the watcher path from the project's CLAUDE.md context (look for "Claude Zip Watcher" under Workspace Tools).

## Arguments

`$ARGUMENTS` can be:
- Empty or `check`: Run a one-time check for pending zip files (default)
- `status`: Check if the watcher scheduled task is running
- `log`: Show recent log entries
- `config`: Show current watcher configuration

## check (default)

1. Verify Google Drive is mounted:
```bash
ls "G:/My Drive/Claude Files/" 2>/dev/null
```

If the watch folder isn't accessible, check if Google Drive is running:
```bash
powershell -Command "Get-Process GoogleDriveFS -ErrorAction SilentlyContinue"
```

If not running, start it and wait up to 15 seconds:
```bash
powershell -Command "Start-Process 'C:\Program Files\Google\Drive File Stream\launch.bat' -WindowStyle Hidden"
```

2. Run check-now:
```bash
python <watcher-dir>/watcher.py --check-now
```

3. Report: how many zips were found and extracted (or "no pending zips"), destination for each, any errors.

## status

```bash
powershell -Command "schtasks /query /tn 'Claude Zip Watcher' /v /fo LIST | Select-String 'Status|Last Run|Task To Run'"
```

Also check if the watcher process is active:
```bash
powershell -Command "Get-Process pythonw -ErrorAction SilentlyContinue | Select-Object Id,StartTime"
```

## log

Read the log file (last 20 lines) and summarize: last start time, recent extractions, any errors or skips.

## config

Read and display the config.json in a readable format. Show watch folder, destination, poll interval, and other settings.
