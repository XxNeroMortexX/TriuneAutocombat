"""Add MQ2WebUpdate to the first-install ZIP and verify MQ root paths."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / "TriuneAutocombat-Install.zip"
DLL = ROOT / "MQ2WebUpdate/MQ2WebUpdate.dll"
DLL_DEST = "plugins/MQ2WebUpdate.dll"


def build() -> None:
    if not ASSET.is_file() or not DLL.is_file():
        raise RuntimeError("Create the TAC install archive first; DLL must exist")
    with ZipFile(ASSET, "a", compression=ZIP_DEFLATED, allowZip64=True) as archive:
        if DLL_DEST in archive.namelist():
            raise RuntimeError("DLL is already in the install archive")
        archive.write(DLL, DLL_DEST)


def verify() -> None:
    if not ASSET.is_file():
        raise RuntimeError("First-install archive is missing")
    with ZipFile(ASSET) as archive:
        names = archive.namelist()
        required = {
            "lua/triune.lua",
            "lua/tac/update_manager.lua",
            "lua/TAC_support_modules/webupdate_dll_handoff.lua",
            "resources/gamedb/manifest.txt",
            DLL_DEST,
        }
        if not required <= set(names):
            raise RuntimeError("Required Lua, database, or plugin DLL is missing")
        if len(names) != len(set(names)) or any(
            name.startswith(("TAC/", "/")) or ".." in Path(name).parts
            for name in names
        ):
            raise RuntimeError("Duplicate or unsafe archive path")
        if any(name.endswith(".navmesh") for name in names):
            raise RuntimeError("Navmeshes must be downloaded separately")
        if hashlib.sha256(archive.read(DLL_DEST)).digest() != hashlib.sha256(DLL.read_bytes()).digest():
            raise RuntimeError("Plugin DLL differs from the published binary")
        if archive.testzip() is not None:
            raise RuntimeError("Corrupt first-install archive")
    print(f"Verified {ASSET.name}: {ASSET.stat().st_size} bytes, {len(names)} root-relative entries")


if __name__ == "__main__":
    if sys.argv[1:] == ["--verify"]:
        verify()
    elif not sys.argv[1:]:
        build()
    else:
        raise SystemExit("Usage: package_release.py [--verify]")
