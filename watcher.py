"""
Watch a folder for new files. Zips are extracted; other files are copied.

Usage:
    python watcher.py                # Run watcher (default)
    python watcher.py --check-now    # One-time poll, then exit
    python watcher.py --poll-interval 300  # Custom poll (seconds)
"""

import argparse
import ctypes
import ctypes.wintypes
import json
import logging
import re
import shutil
import sys
import time
import zipfile
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

SCRIPT_DIR = Path(__file__).resolve().parent
LOG_FILE = SCRIPT_DIR / "unzip-log.txt"
DEFAULT_CONFIG = SCRIPT_DIR / "config.json"

# Win32 constants for exclusive file access check
GENERIC_READ = 0x80000000
FILE_SHARE_NONE = 0
OPEN_EXISTING = 3
FILE_ATTRIBUTE_NORMAL = 0x80
INVALID_HANDLE = ctypes.c_void_p(-1).value

CreateFileW = ctypes.windll.kernel32.CreateFileW
CreateFileW.argtypes = [
    ctypes.wintypes.LPCWSTR,  # lpFileName
    ctypes.wintypes.DWORD,    # dwDesiredAccess
    ctypes.wintypes.DWORD,    # dwShareMode
    ctypes.c_void_p,          # lpSecurityAttributes
    ctypes.wintypes.DWORD,    # dwCreationDisposition
    ctypes.wintypes.DWORD,    # dwFlagsAndAttributes
    ctypes.wintypes.HANDLE,   # hTemplateFile
]
CreateFileW.restype = ctypes.wintypes.HANDLE
CloseHandle = ctypes.windll.kernel32.CloseHandle


def load_config(config_path: Path | None = None) -> dict:
    """Load config from JSON file, merging with defaults."""
    defaults = {
        "watch_folder": "G:\\My Drive\\Claude Files",
        "destination_folder": "C:\\Dev",
        "todo_file": "C:\\Dev\\todo.md",
        "poll_interval_seconds": 600,
        "file_lock_retries": 30,
        "file_lock_retry_delay_seconds": 2,
        "fsw_settle_delay_seconds": 3,
    }
    path = config_path or DEFAULT_CONFIG
    if path.exists():
        with open(path, encoding="utf-8-sig") as f:
            defaults.update(json.load(f))
    return defaults


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Watch for zip files and extract them")
    parser.add_argument("--check-now", action="store_true", help="One-time poll, then exit")
    parser.add_argument("--poll-interval", type=int, help="Poll interval in seconds")
    parser.add_argument("--config", type=Path, help="Path to config.json")
    return parser.parse_args()


def setup_logging(log_file: Path) -> logging.Logger:
    """Configure logger to write to both console and file.

    Matches the existing PowerShell log format: [YYYY-MM-DD HH:MM:SS] message
    """
    logger = logging.getLogger("zip-watcher")
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("[%(asctime)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(fmt)
    logger.addHandler(file_handler)

    # pythonw.exe sets sys.stderr to None -- skip console handler to avoid errors
    if sys.stderr is not None:
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(fmt)
        logger.addHandler(console_handler)

    return logger


def check_drive_mounted(watch_folder: Path) -> bool:
    """Verify the drive root exists (e.g. G:\\ is mounted)."""
    return Path(watch_folder.anchor).exists()


def wait_for_file_ready(file_path: Path, retries: int = 30, delay: float = 2.0) -> bool:
    """Wait for exclusive file access (Google Drive sync completion).

    Uses Win32 CreateFileW with FILE_SHARE_NONE — the exact equivalent of
    .NET's [IO.File]::Open(path, Open, Read, None). Fails if any other
    process has the file open (i.e. Drive is still writing).
    """
    for _ in range(retries):
        handle = CreateFileW(
            str(file_path), GENERIC_READ, FILE_SHARE_NONE,
            None, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None,
        )
        if handle != INVALID_HANDLE:
            CloseHandle(handle)
            return True
        time.sleep(delay)
    return False


def add_todo_entry(todo_file: Path, name: str, logger: logging.Logger, is_file: bool = False) -> None:
    """Append a project section to todo.md if it doesn't already exist."""
    if not todo_file.exists():
        return
    content = todo_file.read_text(encoding="utf-8")
    pattern = rf"(?m)^## \[.*\]\({re.escape(name)}/?\)"
    if re.search(pattern, content):
        return
    link = f"[{name}]({name})" if is_file else f"[{name}]({name}/)"
    entry = f"\n## {link}\n- [ ] Review and determine next steps\n"
    with open(todo_file, "a", encoding="utf-8") as f:
        f.write(entry)
    logger.info("TODO: Added entry for %s", name)


def collapse_nested_folder(extract_to: Path, logger: logging.Logger) -> None:
    """If extracted folder contains exactly one subfolder and nothing else, collapse it."""
    children = list(extract_to.iterdir())
    if len(children) != 1 or not children[0].is_dir():
        return
    inner = children[0]
    items = list(inner.iterdir())
    # Verify no name conflicts before moving
    for item in items:
        if (extract_to / item.name).exists():
            logger.info("SKIP COLLAPSE: %s would conflict with existing item", item.name)
            return
    for item in items:
        item.rename(extract_to / item.name)
    inner.rmdir()
    logger.info("COLLAPSED: %s/ (removed redundant %s/ nesting)", extract_to.name, inner.name)


def process_zip_file(
    file_path: Path,
    destination: Path,
    todo_file: Path,
    logger: logging.Logger,
    lock_retries: int = 30,
    lock_delay: float = 2.0,
) -> None:
    """Extract a zip file to destination, delete original, add todo entry."""
    if not wait_for_file_ready(file_path, lock_retries, lock_delay):
        timeout = int(lock_retries * lock_delay)
        logger.info("TIMEOUT: Could not access %s after %d seconds. Skipping.", file_path, timeout)
        return

    try:
        extract_to = destination / file_path.stem
        is_update = extract_to.exists()
        tmp_dir = destination / f".tmp-{file_path.stem}"

        # Extract to temp dir first, then swap — safe if extraction fails
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir)
        tmp_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(file_path, "r") as zf:
            extract_base = tmp_dir.resolve()
            for member in zf.namelist():
                member_path = (extract_base / member).resolve()
                if not member_path.is_relative_to(extract_base):
                    raise ValueError(f"Zip Slip detected: {member}")
            zf.extractall(tmp_dir)
        collapse_nested_folder(tmp_dir, logger)

        # Swap into place
        if is_update:
            shutil.rmtree(extract_to)
        tmp_dir.rename(extract_to)

        verb = "UPDATED" if is_update else "EXTRACTED"
        logger.info("%s: %s -> %s", verb, file_path, extract_to)

        file_path.unlink()
        logger.info("DELETED: %s", file_path)

        if not is_update:
            add_todo_entry(todo_file, extract_to.name, logger)
    except Exception:
        logger.exception("ERROR processing %s", file_path)


def process_file(
    file_path: Path,
    destination: Path,
    todo_file: Path,
    logger: logging.Logger,
    lock_retries: int = 30,
    lock_delay: float = 2.0,
) -> None:
    """Copy a non-zip file to destination, overwriting if it exists."""
    if not wait_for_file_ready(file_path, lock_retries, lock_delay):
        timeout = int(lock_retries * lock_delay)
        logger.info("TIMEOUT: Could not access %s after %d seconds. Skipping.", file_path, timeout)
        return

    try:
        dest_file = destination / file_path.name
        shutil.copy2(file_path, dest_file)
        logger.info("COPIED: %s -> %s", file_path, dest_file)

        file_path.unlink()
        logger.info("DELETED: %s", file_path)

        add_todo_entry(todo_file, file_path.name, logger, is_file=True)

    except Exception:
        logger.exception("ERROR processing %s", file_path)


def process_incoming(
    file_path: Path,
    destination: Path,
    todo_file: Path,
    logger: logging.Logger,
    config: dict,
) -> None:
    """Route an incoming file to the appropriate processor."""
    if file_path.suffix.lower() == ".zip":
        process_zip_file(
            file_path, destination, todo_file, logger,
            config["file_lock_retries"],
            config["file_lock_retry_delay_seconds"],
        )
    else:
        process_file(
            file_path, destination, todo_file, logger,
            config["file_lock_retries"],
            config["file_lock_retry_delay_seconds"],
        )


class FileEventHandler(FileSystemEventHandler):
    """Handles created and moved files in the watch folder."""

    def __init__(self, destination: Path, todo_file: Path,
                 logger: logging.Logger, config: dict):
        super().__init__()
        self.destination = destination
        self.todo_file = todo_file
        self.logger = logger
        self.config = config
        self.settle_delay = config["fsw_settle_delay_seconds"]

    def _handle(self, file_path: Path, change_type: str) -> None:
        self.logger.info("DETECTED (%s): %s", change_type, file_path)
        time.sleep(self.settle_delay)
        process_incoming(
            file_path, self.destination, self.todo_file, self.logger, self.config,
        )

    def on_created(self, event):
        if not event.is_directory:
            self._handle(Path(event.src_path), "Created")

    def on_moved(self, event):
        if not event.is_directory:
            self._handle(Path(event.dest_path), "Renamed")


def main() -> None:
    args = parse_args()
    config = load_config(args.config)

    if args.poll_interval is not None:
        config["poll_interval_seconds"] = args.poll_interval

    logger = setup_logging(LOG_FILE)

    watch_folder = Path(config["watch_folder"])
    destination = Path(config["destination_folder"])
    todo_file = Path(config["todo_file"])

    # Verify Google Drive is mounted before proceeding
    if not check_drive_mounted(watch_folder):
        logger.info("SKIP: Drive not mounted at %s", watch_folder.anchor)
        return

    # Create directories if needed
    if not watch_folder.exists():
        watch_folder.mkdir(parents=True, exist_ok=True)
        logger.info("Created watch folder: %s", watch_folder)
    if not destination.exists():
        destination.mkdir(parents=True, exist_ok=True)
        logger.info("Created destination folder: %s", destination)

    # Process any existing files on startup
    existing = sorted(f for f in watch_folder.glob("*") if f.is_file())
    for file_path in existing:
        logger.info("Found existing file: %s", file_path)
        process_incoming(file_path, destination, todo_file, logger, config)

    # CheckNow mode: one-time poll, then exit
    if args.check_now:
        if not existing:
            logger.info("CHECK: No files found.")
        return

    # Set up watchdog observer (uses ReadDirectoryChangesW on Windows,
    # same underlying API as .NET's FileSystemWatcher)
    event_handler = FileEventHandler(destination, todo_file, logger, config)
    observer = Observer()
    observer.schedule(event_handler, str(watch_folder), recursive=False)
    observer.start()

    logger.info("=== Watcher started ===")
    logger.info("Watching: %s", watch_folder)
    logger.info("Extracting to: %s", destination)
    logger.info("Press Ctrl+C to stop.")

    try:
        poll_interval = config["poll_interval_seconds"]
        while True:
            time.sleep(poll_interval)
            # Polling fallback — catches anything the observer missed
            for file_path in sorted(f for f in watch_folder.glob("*") if f.is_file()):
                logger.info("POLL: Found %s", file_path)
                process_incoming(file_path, destination, todo_file, logger, config)
    except KeyboardInterrupt:
        pass
    finally:
        observer.stop()
        observer.join()
        logger.info("=== Watcher stopped ===")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # pythonw.exe has no console — unhandled exceptions vanish silently.
        # Write to a fallback error file so failures are discoverable.
        error_file = SCRIPT_DIR / "watcher-error.txt"
        import traceback
        with open(error_file, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] ")
            traceback.print_exc(file=f)
        raise
