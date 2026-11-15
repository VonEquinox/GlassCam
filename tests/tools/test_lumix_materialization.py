import hashlib
import importlib.util
import json
import os
from pathlib import Path
import zipfile

import pytest


module = importlib.util.spec_from_file_location(
    "prepare_lumix_resources",
    Path(__file__).resolve().parents[2] / "scripts/prepare_lumix_resources.py",
)
materialization = importlib.util.module_from_spec(module)
module.loader.exec_module(materialization)


@pytest.fixture
def resource_archive(tmp_path):
    payloads = {f"L{index:05d}.lmx": f"frozen-resource-{index}".encode()
                for index in range(16)}
    manifest = {
        "schemaVersion": 1,
        "looks": [{"asset": name} for name in payloads],
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()},
    }
    archive = tmp_path / "source.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        for name, data in payloads.items():
            bundle.writestr(name, data)
        bundle.writestr("manifest.json", json.dumps(manifest))
    (tmp_path / "SHA256SUMS").write_text(
        hashlib.sha256(archive.read_bytes()).hexdigest() + "  source.zip\n"
    )
    return archive, payloads


@pytest.mark.parametrize("mutation", ["modified", "missing", "truncated"])
def test_cached_resource_damage_is_restored_from_verified_archive(resource_archive, tmp_path, mutation):
    archive, payloads = resource_archive
    destination = tmp_path / "resources"
    materialization.prepare(archive, destination)
    name, expected = next(iter(payloads.items()))
    resource = destination / name
    if mutation == "missing":
        resource.unlink()
    else:
        resource.write_bytes(b"wrong" if mutation == "modified" else b"")

    materialization.prepare(archive, destination)

    assert resource.read_bytes() == expected


def test_cached_manifest_damage_is_restored_from_verified_archive(resource_archive, tmp_path):
    archive, _ = resource_archive
    destination = tmp_path / "resources"
    materialization.prepare(archive, destination)
    manifest = destination / "manifest.json"
    manifest.write_bytes(b"{broken")
    with zipfile.ZipFile(archive) as bundle:
        expected = bundle.read("manifest.json")

    materialization.prepare(archive, destination)

    assert manifest.read_bytes() == expected


def test_existing_resources_do_not_hide_archive_checksum_failure(resource_archive, tmp_path):
    archive, _ = resource_archive
    destination = tmp_path / "resources"
    materialization.prepare(archive, destination)
    before = archive.stat()
    damaged = bytearray(archive.read_bytes())
    damaged[0] ^= 1
    archive.write_bytes(damaged)
    os.utime(archive, ns=(before.st_atime_ns, before.st_mtime_ns))

    with pytest.raises(RuntimeError, match="archive failed SHA-256 verification"):
        materialization.prepare(archive, destination)
