"""Materialize the hash-locked, losslessly packed FFCS integer mappings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

ARCHIVE_SHA256 = "51f0049f5f55732523176a3fccc120ea8a068d4fbbc5658f21fabec9d56b22d6"
RESOURCE_PATH = re.compile(r"(xh2s|xa3|gfx100|gfx100s|gfx100ii)/[a-z0-9_]+\.ffcm")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def prepare(archive_path, output):
    if digest(archive_path) != ARCHIVE_SHA256:
        raise ValueError("FFCS mapping archive SHA256 mismatch")
    with zipfile.ZipFile(archive_path) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        if manifest["schema"] != 1 or manifest["codec"] != "channel-delta-u16-zlib":
            raise ValueError("Unsupported FFCS mapping manifest")
        resources = manifest["resources"]
        if len(resources) != 50 or len({row["path"] for row in resources}) != 50:
            raise ValueError("Invalid FFCS mapping resource list")
        for row in resources:
            name = row["path"]
            if not RESOURCE_PATH.fullmatch(name):
                raise ValueError("Invalid FFCS mapping resource path")
            destination = output / name
            if destination.is_file() and digest(destination) == row["sha256"]:
                continue
            data = archive.read(name)
            if hashlib.sha256(data).hexdigest() != row["sha256"]:
                raise ValueError("FFCS mapping resource SHA256 mismatch")
            destination.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix=".mapping-", dir=destination.parent)
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(data)
                os.replace(temporary, destination)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path,
                        default=Path(__file__).resolve().parents[1] / "vendor/ffcs/mapping.zip")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.archive, args.output)
    print("FFCS: original integer mappings verified.")


if __name__ == "__main__":
    main()
