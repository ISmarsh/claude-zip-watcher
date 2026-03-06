---
name: unpack-gdrive-projects
description: Manage the Google Drive file watcher - check for pending files, view logs, show config
user-invocable: true
allowed-tools:
  - Bash(python *)
  - Bash(powershell *)
  - Read
argument-hint: "[check|log|config]"
---

# Unpack Google Drive Projects

Manage the Claude File Watcher that processes files from Google Drive into the dev workspace. Zips are extracted (with nested folder collapsing and update-in-place for duplicates). Other files are copied directly.

The watcher runs automatically when the VSCode workspace opens (via a folder-open task). This skill provides manual control.

Find the watcher path from the project's CLAUDE.md context (look for "Claude Zip Watcher" under Workspace Tools).

## Arguments

`$ARGUMENTS` can be:
- Empty or `check`: Run a one-time check for pending files (default)
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

3. Report: how many files were processed (or "no pending files"), destination for each, noting EXTRACTED/UPDATED/COPIED/COLLAPSED status, and any errors.

## log

Read the log file (last 20 lines) and summarize: last start time, recent extractions, any errors or skips.

## config

Read and display the config.json in a readable format. Show watch folder, destination, poll interval, and other settings.
