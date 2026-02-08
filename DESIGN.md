# Design Decisions

## Problem

Claude Code sessions on mobile/web can generate zip files, but there's no built-in way to get them onto a local dev machine. Google Drive bridges the gap -- upload from phone, auto-sync to desktop -- but watching a cloud-synced virtual filesystem has several non-obvious gotchas.

## Why Python (v2)

The original implementation used PowerShell. It worked well but had one persistent annoyance: PowerShell console windows flashed briefly every time the scheduled task launched the watcher. PowerShell's `-WindowStyle Hidden` flag doesn't prevent the initial console creation -- a Windows console subsystem limitation that affects all CLI runtimes (PowerShell, Node.js, Python's `python.exe`).

**`pythonw.exe`** is Python's GUI-subsystem executable. Windows never creates a console window for it, period. This eliminates the flash entirely without needing a VBScript wrapper (which Microsoft is deprecating).

The rewrite also externalized configuration from hardcoded script variables to `config.json`, removing the fragile regex-edit-the-script pattern the PowerShell setup used.

## Architecture: Observer + Polling Hybrid

The watcher uses two detection mechanisms in parallel:

1. **watchdog Observer** (event-driven) -- for near-instant detection when events fire
2. **10-minute polling fallback** -- catches anything the observer misses

### Why not just the observer?

Python's `watchdog` library uses `ReadDirectoryChangesW` on Windows -- the same Win32 API that .NET's `FileSystemWatcher` wraps. Google Drive's stream mode uses a minifilter driver (`cldflt.sys`) that serves files through a virtual filesystem. This driver doesn't reliably generate the NTFS change notifications that `ReadDirectoryChangesW` depends on.

This is a known limitation documented in [dotnet/runtime#16924](https://github.com/dotnet/runtime/issues/16924). The .NET team themselves proposed a polling API as a workaround in [dotnet/runtime#17111](https://github.com/dotnet/runtime/issues/17111).

### Why not just polling?

Polling alone works fine but adds latency. When observer events *do* fire, they provide near-instant detection. The hybrid approach gives you the best of both: instant when available, reliable always.

### Why 10 minutes?

In practice, the observer catches events reliably on Google Drive's stream mode -- all test runs showed 100% event-driven detection with zero polling catches. The polling exists as insurance for the documented edge cases where virtual filesystem drivers silently drop events. Since the expected miss rate is near-zero, a 10-minute interval keeps the safety net without wasting cycles. For immediate checks, use `check_now.py` or `--check-now`.

The poll interval is configurable via `config.json` or `--poll-interval <seconds>`.

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

## Scheduled Task Resilience

The watcher runs as a long-lived background process launched by Task Scheduler via `pythonw.exe`. Several settings prevent it from silently dying:

- **No execution time limit** -- The default 72-hour limit would kill the watcher after 3 days. Set to indefinite (`PT0S`).
- **Battery-safe** -- `StopIfGoingOnBatteries` and `DisallowStartIfOnBatteries` are both disabled. The watcher should run on laptops regardless of power state.
- **Restart on failure** -- Up to 3 automatic restarts at 1-minute intervals if the process crashes.
- **30-minute heartbeat trigger** -- The logon trigger includes a repetition interval that re-launches the watcher every 30 minutes. `MultipleInstances = IgnoreNew` prevents duplicates when the process is already running; the trigger only has an effect if the process has died silently (e.g., after sleep/wake).
- **StartWhenAvailable** -- If the machine was off when a trigger fired, the task runs as soon as possible after.

## Error Visibility with pythonw.exe

Since `pythonw.exe` has no console, unhandled exceptions vanish silently. The watcher wraps `main()` in a top-level try/except that writes tracebacks to `watcher-error.txt` as a fallback for failures that occur before logging is configured (e.g., malformed `config.json`).

## Duplicate Handling

If a zip's target folder already exists (e.g., extracting `project.zip` when `C:\Dev\project\` exists), the script appends a counter suffix (`project_2`, `project_3`, etc.) rather than overwriting.

## Configuration

Config is externalized to `config.json` rather than hardcoded in the script. The setup wizard edits this file via `ConvertFrom-Json`/`ConvertTo-Json` instead of regex-replacing script contents -- a cleaner and less fragile approach.
