# Design Decisions

## Problem

Claude Code sessions on mobile/web can generate zip files, but there's no built-in way to get them onto a local dev machine. Google Drive bridges the gap — upload from phone, auto-sync to desktop — but watching a cloud-synced virtual filesystem has several non-obvious gotchas.

## Architecture: FSW + Polling Hybrid

The watcher uses two detection mechanisms in parallel:

1. **FileSystemWatcher** (event-driven) — for near-instant detection when events fire
2. **10-minute polling fallback** — catches anything FSW misses

### Why not just FSW?

.NET's `FileSystemWatcher` wraps the Win32 `ReadDirectoryChangesW` API, which was designed for local NTFS volumes. Google Drive's stream mode uses a minifilter driver (`cldflt.sys`) that serves files through a virtual filesystem. This driver doesn't reliably generate the NTFS change notifications that `ReadDirectoryChangesW` depends on.

This is a known limitation documented in [dotnet/runtime#16924](https://github.com/dotnet/runtime/issues/16924). The .NET team themselves proposed a polling API as a workaround in [dotnet/runtime#17111](https://github.com/dotnet/runtime/issues/17111).

### Why not just polling?

Polling alone works fine but adds latency. When FSW events *do* fire, they provide near-instant detection. The hybrid approach gives you the best of both: instant when available, reliable always.

### Why 10 minutes?

In practice, FSW catches events reliably on Google Drive's stream mode — all test runs showed 100% FSW detection with zero polling catches. The polling exists as insurance for the documented edge cases where virtual filesystem drivers silently drop events. Since the expected miss rate is near-zero, a 10-minute interval keeps the safety net without wasting cycles. For immediate checks, use `check-now.ps1` or `-CheckNow`.

The poll interval is configurable via `-PollInterval <seconds>`.

## FSW Hardening

Three settings reduce the chance of silent event loss:

- **`InternalBufferSize = 65536`** — The default 8 KB kernel buffer overflows silently under load, causing FSW to lose events without warning. 64 KB is the maximum effective size for non-local paths.
- **`NotifyFilter = FileName`** — Only listen for file creation/rename events. Ignoring attribute, size, and timestamp changes reduces notification volume and decreases the chance of buffer overflow.
- **`Error` event handler** — When buffer overflow does occur, trigger an immediate poll instead of waiting for the next scheduled poll.

## Google Drive: Stream Mode, Not Mirror

**Mirror mode syncs deletions bidirectionally.** If a local process deletes or moves a file that was synced via mirror mode, the deletion propagates to Google Drive's cloud storage. This caused actual data loss during development — files deleted locally were removed from the cloud drive.

**Stream mode** presents files through a virtual drive letter. Files live in the cloud and are hydrated (downloaded) on demand. Local operations on the virtual filesystem don't propagate destructive changes upstream. The tradeoff is that FSW is unreliable (see above), which the polling fallback handles.

### Existing Installation Gotcha

Stream mode is the default on **fresh** installations. But if Google Drive was previously installed (even if uninstalled and reinstalled), leftover config in `%LocalAppData%\Google\DriveFS\` can preserve mirror mode preferences. The setup script checks for existing installations and warns about this, since there's no registry key or CLI flag to force stream mode programmatically on personal accounts.

### Drive Letter Assignment

Stream mode doesn't assign a drive letter by default. It mounts as a virtual location in File Explorer. The setup script pre-seeds the drive letter via registry (`HKLM\SOFTWARE\Google\DriveFS\DefaultMountPoint`) before first launch.

For manual setup: Google Drive settings → gear icon → Preferences → click the "virtual drive or folder" link (nested preferences window) → assign a drive letter.

## File Locking and Sync Delay

Google Drive may still be writing a file when the watcher detects it. The script handles this with a retry loop that attempts to open the file exclusively, waiting up to 60 seconds (30 retries × 2 seconds) for the sync to complete.

## Duplicate Handling

If a zip's target folder already exists (e.g., extracting `project.zip` when `C:\Dev\project\` exists), the script appends a counter suffix (`project_2`, `project_3`, etc.) rather than overwriting.
