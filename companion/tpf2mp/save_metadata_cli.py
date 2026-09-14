"""Read-only native save inspection command registration and dispatch."""
from __future__ import annotations

import json
from pathlib import Path

from .save_metadata import inspect_save_directory, validate_metadata


def configure_cli(commands) -> None:
    metadata = commands.add_parser("validate-save-metadata", help="check native save Lua data without executing it")
    metadata.add_argument("save", type=Path)
    browser = commands.add_parser("inspect-save-directory", help="read-only native save-browser metadata diagnostic")
    browser.add_argument("directory", type=Path)


def run_cli(args) -> bool:
    if args.command == "validate-save-metadata":
        print(f"save_metadata_valid={validate_metadata(args.save)}")
    elif args.command == "inspect-save-directory":
        print(json.dumps(inspect_save_directory(args.directory), sort_keys=True))
    else:
        return False
    return True
