# Claude GDrive Intake

Automatically processes files dropped into a Google Drive folder — zip files are extracted, other files are copied. Built for getting Claude Code session exports from mobile/web onto a dev machine without manual steps.

## How It Works

1. Google Drive syncs a "Claude Files" folder to your PC via stream mode
2. When you open your dev workspace in VSCode, a folder-open task runs `--check-now`
3. Any pending files are processed: zips are extracted and other files are copied to your destination folder, then originals are deleted
4. A todo entry is auto-added to your workspace todo.md for each processed file

## Requirements

- Windows 10/11
- Python 3.11+ (`pythonw.exe` must be on PATH)
- Google Drive for Desktop (stream mode)

## Quick Start

1. Install the dependency:

```bash
pip install watchdog
```

2. Run the setup script as administrator (configures Google Drive):

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

3. Add a VSCode task to your workspace `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "GDrive Intake",
      "type": "process",
      "command": "pythonw",
      "args": ["${workspaceFolder}/claude-gdrive-intake/watcher.py", "--check-now"],
      "presentation": { "reveal": "silent" },
      "runOptions": { "runOn": "folderOpen" }
    }
  ]
}
```

This runs the intake automatically every time you open the workspace -- no background process, no polling, no window flash.

## Usage

```bash
# One-time check for pending files (what the VSCode task runs)
python watcher.py --check-now

# Start manually (visible console, for debugging)
python watcher.py

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
- `/unpack-gdrive-projects` -- check for pending files
- `/unpack-gdrive-projects log` -- show recent activity
- `/unpack-gdrive-projects config` -- show current settings

## Files

| File | Purpose |
|------|---------|
| `watcher.py` | Core processor (`--check-now` for one-shot, or long-running with observer + polling) |
| `config.json` | Watch folder, destination, poll interval, etc. |
| `setup.ps1` | Interactive setup wizard for Google Drive configuration |
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

## Background Watcher (alternative)

The long-running mode (`python watcher.py` without `--check-now`) uses a watchdog observer with a polling fallback. This was the original approach, using a scheduled task to run at login. See `setup.ps1` step 3 for scheduled task registration if you prefer continuous monitoring over the VSCode folder-open approach.

## License

MIT
