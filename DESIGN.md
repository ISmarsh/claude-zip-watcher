# Design Decisions

## Problem

Claude Code sessions on mobile/web can generate zip files, but there's no built-in way to get them onto a local dev machine. Google Drive bridges the gap -- upload from phone, auto-sync to desktop -- but watching a cloud-synced virtual filesystem has several non-obvious gotchas.

## Why Python (v2)

The original implementation used PowerShell. It worked well but had one persistent annoyance: PowerShell console windows flashed briefly every time the scheduled task launched the watcher. PowerShell's `-WindowStyle Hidden` flag doesn't prevent the initial console creation -- a Windows console subsystem limitation that affects all CLI runtimes (PowerShell, Node.js, Python's `python.exe`).

**`pythonw.exe`** is Python's GUI-subsystem executable. Windows never creates a console window for it, period. This eliminates the flash entirely without needing a VBScript wrapper (which Microsoft is deprecating).

The rewrite also externalized configuration from hardcoded script variables to `config.json`, removing the fragile regex-edit-the-script pattern the PowerShell setup used.

## Architecture: VSCode Folder-Open (v3)

The primary trigger is now a VSCode task with `"runOn": "folderOpen"`. When the dev workspace opens, VSCode runs `watcher.py --check-now` via `pythonw.exe` (no window flash). This processes any pending files, then exits.

### Why not a background watcher?

The previous approach (v2) ran a long-lived process via scheduled task with a watchdog observer and 10-minute polling fallback. This worked but added unnecessary complexity:

- A background process running 24/7 for a job that only matters when you sit down to work
- Scheduled task management (admin privileges, heartbeat triggers, crash recovery)
- Observer unreliability on Google Drive's virtual filesystem ([dotnet/runtime#16924](https://github.com/dotnet/runtime/issues/16924))

The folder-open approach eliminates all of this. Files sit in Google Drive until you open VSCode, which is exactly when you'd process them anyway. The `--check-now` flag handles the one-shot intake cleanly.

### Background watcher (archived alternative)

The long-running mode (`python watcher.py` without `--check-now`) still works and uses two detection mechanisms in parallel:

1. **watchdog Observer** (event-driven) -- for near-instant detection when events fire
2. **Polling fallback** -- catches anything the observer misses (configurable interval, default 10 minutes)

This is useful if you need near-real-time detection without VSCode open. See `setup.ps1` for scheduled task registration.

## Observer Hardening

The `watchdog` Observer on Windows uses `ReadDirectoryChangesW` with a 64 KB buffer by default -- the maximum effective size for non-local paths. This matches the hardening the PowerShell version applied manually.

Unlike .NET's `FileSystemWatcher`, `watchdog` doesn't expose a direct "buffer overflow" error event. The polling fallback serves the same recovery purpose: if the observer silently loses events, the next poll cycle catches them.

## File Locking on Windows

Google Drive may still be writing a file when the watcher detects it. The watcher handles this with a retry loop using Win32's `CreateFileW` with `FILE_SHARE_NONE` (via `ctypes`).

Python's built-in `open()` does **not** exclusively lock files on Windows -- it uses `FILE_SHARE_READ | FILE_SHARE_WRITE` by default. To match the PowerShell version's `[IO.File]::Open(path, Open, Read, None)` behavior, we call `CreateFileW` directly through `ctypes` with `dwShareMode=0`. This fails if any other process (like Google Drive's sync) has the file open.

## Google Drive: Stream Mode, Not Mirror

**Mirror mode syncs deletions bidirectionally.** If a local process deletes or moves a file that was synced via mirror mode, the deletion propagates to Google Drive's cloud storage. This caused actual data loss during development -- files deleted locally were removed from the cloud drive.

**Stream mode** presents files through a virtual drive letter. Files live in the cloud and are hydrated (downloaded) on demand. Local operations on the virtual filesystem don't propagate destructive changes upstream. The tradeoff is that the observer is unreliable (see above), which the polling fallback handles.

### Existing Installation Gotcha

Stream mode is the default on **fresh** installations. But if Google Drive was previously installed (even if uninstalled and reinstalled), leftover config in `%LocalAppData%\Google\DriveFS\` can preserve mirror mode preferences. The setup script checks for existing installations and warns about this, since there's no registry key or CLI flag to force stream mode programmatically on personal accounts.

### Drive Letter Assignment

Stream mode doesn't assign a drive letter by default. It mounts as a virtual location in File Explorer. The setup script pre-seeds the drive letter via registry (`HKLM\SOFTWARE\Google\DriveFS\DefaultMountPoint`) before first launch.

For manual setup: Google Drive settings > gear icon > Preferences > click the "virtual drive or folder" link (nested preferences window) > assign a drive letter.

## Drive Mount Check

Before starting, the watcher verifies that the drive root (e.g., `G:\`) exists. Without this check, the script would create a local directory at the path (e.g., `G:\My Drive\Claude Files` as a regular folder on a non-existent drive) and watch an empty local folder. With the check, the watcher exits cleanly with a `SKIP` log entry, and the scheduled task's 30-minute heartbeat retries later.

## Scheduled Task Resilience (archived -- background watcher only)

When using the long-running background watcher (not the recommended VSCode folder-open approach), the scheduled task has several resilience settings:

- **No execution time limit** -- The default 72-hour limit would kill the watcher after 3 days. Set to indefinite (`PT0S`).
- **Battery-safe** -- `StopIfGoingOnBatteries` and `DisallowStartIfOnBatteries` are both disabled.
- **Restart on failure** -- Up to 3 automatic restarts at 1-minute intervals.
- **30-minute heartbeat trigger** -- Re-launches every 30 minutes if the process died silently. `MultipleInstances = IgnoreNew` prevents duplicates.
- **StartWhenAvailable** -- If the machine was off when a trigger fired, the task runs as soon as possible after.

## Error Visibility with pythonw.exe

Since `pythonw.exe` has no console, unhandled exceptions vanish silently. The watcher wraps `main()` in a top-level try/except that writes tracebacks to `watcher-error.txt` as a fallback for failures that occur before logging is configured (e.g., malformed `config.json`).

## Duplicate Handling

If a zip's target folder already exists (e.g., extracting `project.zip` when `C:\Dev\project\` exists), the script appends a counter suffix (`project_2`, `project_3`, etc.) rather than overwriting.

## Configuration

Config is externalized to `config.json` rather than hardcoded in the script. The setup wizard edits this file via `ConvertFrom-Json`/`ConvertTo-Json` instead of regex-replacing script contents -- a cleaner and less fragile approach.
