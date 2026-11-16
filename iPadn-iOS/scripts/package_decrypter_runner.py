#!/usr/bin/env python3
"""Package the separately built unsigned runner as a resource, never nested code."""
import argparse
import os
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runner_app", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
bundle = args.runner_app
info_path = bundle / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
if (bundle / "_CodeSignature").exists() or (bundle / "embedded.mobileprovision").exists():
    raise SystemExit("Build the runner with CODE_SIGNING_ALLOWED=NO before packaging.")
info["TetherDecryptCommit"] = subprocess.check_output(
    ["git", "-C", str(root), "rev-parse", "--short=7", "HEAD"], text=True).strip()
info_path.write_bytes(plistlib.dumps(info))
os.chmod(info_path, 0o644)
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=args.output.parent, suffix=".ipa", delete=False) as temporary:
    staged = Path(temporary.name)
try:
    with zipfile.ZipFile(staged, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(bundle.rglob("*")):
            if file.is_symlink():
                raise SystemExit("Unexpected symlink in runner template: " + str(file))
            if file.is_file():
                archive.write(file, "Payload/" + bundle.name + "/" + file.relative_to(bundle).as_posix())
    os.chmod(staged, 0o644)
    os.replace(staged, args.output)
finally:
    staged.unlink(missing_ok=True)
print("Packaged runner template:", args.output)
