# Claude Zip Watcher

Automatically extracts zip files dropped into a Google Drive folder to a local directory. Built for getting Claude Code session exports from mobile/web onto a dev machine without manual steps.

## How It Works

1. Google Drive syncs a "Claude Files" folder to your PC via stream mode
2. A watchdog observer detects new `.zip` files in near-real-time
3. A 10-minute polling fallback catches anything the observer misses (rare on Google Drive, but [documented](https://github.com/dotnet/runtime/issues/16924))
4. Each zip is extracted to your destination folder, then deleted from the watch folder
5. A todo entry is auto-added to your workspace todo.md

## Requirements

- Windows 10/11
- Python 3.11+ (`pythonw.exe` must be on PATH)
- Google Drive for Desktop (stream mode)

## Quick Start

Install the dependency:

```bash
pip install watchdog
```

Run the setup script as administrator:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

The setup wizard will:
- Verify Python and watchdog are available
- Install Google Drive for Desktop (or detect an existing install)
- Configure the drive letter and watch folder
- Register a scheduled task to run the watcher at login (via `pythonw.exe` -- zero window flash)

## Usage

The watcher runs automatically at login. You can also:

```bash
# Start manually (visible console)
python watcher.py

# Start in background (no window)
pythonw.exe watcher.py

# One-time check for pending zips
python watcher.py --check-now

# Custom poll interval (seconds)
python watcher.py --poll-interval 300
```

## Claude Code Skill

A `/unpack-gdrive-projects` skill is included for managing the watcher from Claude Code.

Install it:

```bash
cp -r skill/ ~/.claude/skills/unpack-gdrive-projects/
```

Then use:
- `/unpack-gdrive-projects` -- check for pending zips
- `/unpack-gdrive-projects status` -- check watcher health
- `/unpack-gdrive-projects log` -- show recent activity
- `/unpack-gdrive-projects config` -- show current settings

## Files

| File | Purpose |
|------|---------|
| `watcher.py` | Core watcher (watchdog observer + polling hybrid) |
| `watcher.py --check-now` | Manual one-time check |
| `config.json` | Watch folder, destination, poll interval, etc. |
| `setup.ps1` | Interactive setup wizard (idempotent, safe to re-run) |
| `skill/SKILL.md` | Claude Code skill definition |
| `DESIGN.md` | Architecture decisions and rationale |

## Configuration

Edit `config.json`:

```json
{
  "watch_folder": "G:\\My Drive\\Claude Files",
  "destination_folder": "C:\\Dev",
  "todo_file": "C:\\Dev\\todo.md",
  "poll_interval_seconds": 600
}
```

Or use `setup.ps1` to configure interactively.

## License

MIT
