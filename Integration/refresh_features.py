#!/usr/bin/env python3
"""Reconstruct the pinned FreeSleepKit import without discarding local edits."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("source", type=pathlib.Path, help="Free Sleep repository checkout at the pinned revision")
parser.add_argument("--check", action="store_true", help="Verify the current module without changing it")
arguments = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((root / "Integration/source-manifest.json").read_text())
source = arguments.source.resolve() / "ios/FreeSleep"
for relative, expected in manifest["sourceFilesSHA256"].items():
    file = source / relative
    if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Source changed: {relative}. Review the new revision and rebase the integration patch first.")

with tempfile.TemporaryDirectory(prefix="free-sleep-import-") as folder:
    staging = pathlib.Path(folder)
    imported = staging / "FreeSleepKit"
    shutil.copytree(source, imported, ignore=shutil.ignore_patterns("AppIcon.appiconset", ".DS_Store"))
    subprocess.run(["git", "init", "-q", str(staging)], check=True)
    subprocess.run(["git", "-C", str(staging), "apply", str(root / "Integration/FreeSleepKit.patch")], check=True)
    changes = [str(file.relative_to(imported)) for file in imported.rglob("*") if file.is_file()
               and (not (root / "FreeSleepKit" / file.relative_to(imported)).is_file()
                    or file.read_bytes() != (root / "FreeSleepKit" / file.relative_to(imported)).read_bytes())]
    if arguments.check:
        if changes:
            raise SystemExit("Import differs: " + ", ".join(changes))
        print("Pinned feature import and overlay match.")
    else:
        if changes:
            raise SystemExit("Local feature edits would be overwritten: " + ", ".join(changes)
                             + ". Incorporate them into FreeSleepKit.patch first.")
        shutil.copytree(imported, root / "FreeSleepKit", dirs_exist_ok=True)
        print("Pinned feature import refreshed.")
