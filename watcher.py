"""
Watch a folder for new .zip files, extract them, and delete the originals.

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
import os
import re
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
        with open(path, encoding="utf-8") as f:
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


def resolve_extract_path(destination: Path, folder_name: str) -> Path:
    """Resolve extraction path, appending _2, _3, etc. for duplicates."""
    extract_to = destination / folder_name
    if not extract_to.exists():
        return extract_to
    counter = 2
    while (destination / f"{folder_name}_{counter}").exists():
        counter += 1
    return destination / f"{folder_name}_{counter}"


def add_todo_entry(todo_file: Path, folder_name: str, logger: logging.Logger) -> None:
    """Append a project section to todo.md if it doesn't already exist."""
    if not todo_file.exists():
        return
    content = todo_file.read_text(encoding="utf-8")
    pattern = rf"(?m)^## \[.*\]\({re.escape(folder_name)}/?\)"
    if re.search(pattern, content):
        return
    entry = f"\n## [{folder_name}]({folder_name}/)\n- [ ] Review and determine next steps\n"
    with open(todo_file, "a", encoding="utf-8") as f:
        f.write(entry)
    logger.info("TODO: Added entry for %s", folder_name)


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
        folder_name = file_path.stem
        extract_to = resolve_extract_path(destination, folder_name)
        extract_to.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(file_path, "r") as zf:
            zf.extractall(extract_to)
        logger.info("EXTRACTED: %s -> %s", file_path, extract_to)

        file_path.unlink()
        logger.info("DELETED: %s", file_path)

        add_todo_entry(todo_file, extract_to.name, logger)
    except Exception as e:
        logger.info("ERROR processing %s : %s", file_path, e)


class ZipEventHandler(FileSystemEventHandler):
    """Handles created and moved .zip files in the watch folder."""

    def __init__(self, destination: Path, todo_file: Path,
                 logger: logging.Logger, config: dict):
        super().__init__()
        self.destination = destination
        self.todo_file = todo_file
        self.logger = logger
        self.config = config
        self.settle_delay = config["fsw_settle_delay_seconds"]

    def _handle(self, file_path: Path, change_type: str) -> None:
        if file_path.suffix.lower() != ".zip":
            return
        self.logger.info("DETECTED (%s): %s", change_type, file_path)
        time.sleep(self.settle_delay)
        process_zip_file(
            file_path, self.destination, self.todo_file, self.logger,
            self.config["file_lock_retries"],
            self.config["file_lock_retry_delay_seconds"],
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

    # Process any existing .zip files on startup
    existing = sorted(watch_folder.glob("*.zip"))
    for zip_path in existing:
        logger.info("Found existing zip: %s", zip_path)
        process_zip_file(
            zip_path, destination, todo_file, logger,
            config["file_lock_retries"],
            config["file_lock_retry_delay_seconds"],
        )

    # CheckNow mode: one-time poll, then exit
    if args.check_now:
        if not existing:
            logger.info("CHECK: No zip files found.")
        return

    # Set up watchdog observer (uses ReadDirectoryChangesW on Windows,
    # same underlying API as .NET's FileSystemWatcher)
    event_handler = ZipEventHandler(destination, todo_file, logger, config)
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
            for zip_path in sorted(watch_folder.glob("*.zip")):
                logger.info("POLL: Found %s", zip_path)
                process_zip_file(
                    zip_path, destination, todo_file, logger,
                    config["file_lock_retries"],
                    config["file_lock_retry_delay_seconds"],
                )
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
