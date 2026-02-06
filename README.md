# Claude Zip Watcher

Automatically extracts zip files dropped into a Google Drive folder to a local directory. Built for getting Claude Code session exports from mobile/web onto a dev machine without manual steps.

## How It Works

1. Google Drive syncs a "Claude Files" folder to your PC via stream mode
2. A FileSystemWatcher detects new `.zip` files in near-real-time
3. A 10-minute polling fallback catches anything FSW misses (rare on Google Drive, but [documented](https://github.com/dotnet/runtime/issues/16924))
4. Each zip is extracted to your destination folder, then deleted from the watch folder

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Google Drive for Desktop (stream mode)

## Quick Start

Run the setup script as administrator:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

The setup wizard will:
- Install Google Drive for Desktop (or detect an existing install)
- Configure the drive letter and watch folder
- Register a scheduled task to run the watcher at login

## Usage

The watcher runs automatically at login. You can also:

```powershell
# Start manually
.\watch-and-unzip.ps1

# One-time check for pending zips
.\check-now.ps1

# Custom poll interval (seconds)
.\watch-and-unzip.ps1 -PollInterval 300
```

## Files

| File | Purpose |
|------|---------|
| `watch-and-unzip.ps1` | Core watcher (FSW + polling hybrid) |
| `setup.ps1` | Interactive setup wizard (idempotent, safe to re-run) |
| `check-now.ps1` | Manual one-time check |
| `DESIGN.md` | Architecture decisions and rationale |

## Configuration

Edit the variables at the top of `watch-and-unzip.ps1`:

```powershell
$WatchFolder = "G:\My Drive\Claude Files"
$DestinationFolder = "C:\Dev"
```

Or use `setup.ps1` to configure the destination folder interactively.

## License

MIT
