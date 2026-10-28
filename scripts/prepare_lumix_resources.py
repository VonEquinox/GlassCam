"""Materialize and verify the portable LUMIX resources without the source app."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def prepare(archive: Path, destination: Path):
    sums = dict(line.split()[::-1] for line in (archive.parent / "SHA256SUMS").read_text().splitlines())
    expected = sums[archive.name]
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError("The LUMIX resource archive failed SHA-256 verification")
    with zipfile.ZipFile(archive) as bundle:
        manifest_bytes = bundle.read("manifest.json")
        manifest = json.loads(manifest_bytes)
        schema = manifest.get("schemaVersion")
        if schema not in (1, 2) or len(manifest.get("looks", [])) != 16:
            raise RuntimeError("Invalid LUMIX manifest")
        files = manifest["files"]
        if len(files) != (16 if schema == 1 else 17) or set(bundle.namelist()) != set(files) | {"manifest.json"}:
            raise RuntimeError("Unexpected LUMIX resource entries")
        destination.mkdir(parents=True, exist_ok=True)
        for name, digest in files.items():
            if Path(name).name != name or not (name.endswith(".lmx") or (schema == 2 and name == "pipeline.lmp")):
                raise RuntimeError("Invalid LUMIX resource path")
            path = destination / name
            if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
                continue
            data = bundle.read(name)
            if hashlib.sha256(data).hexdigest() != digest:
                raise RuntimeError(f"LUMIX resource checksum failed: {name}")
            with tempfile.NamedTemporaryFile(dir=destination, delete=False) as temporary:
                temporary.write(data)
                staged = temporary.name
            os.replace(staged, path)
        (destination / ("manifest.json" if schema == 1 else "pipeline-manifest.json")).write_bytes(manifest_bytes)
    print(f"Verified {len(files)} LUMIX Photo Style LUTs in {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=ROOT / "vendor/lumix/source.zip")
    parser.add_argument("--output", type=Path, default=ROOT / "App/GlassCam/Resources/LUMIX")
    args = parser.parse_args()
    prepare(args.archive, args.output)
    if args.archive.name == "source.zip":
        prepare(args.archive.parent / "pipeline.zip", args.output)


if __name__ == "__main__":
    main()
