import hashlib
import os
from pathlib import Path
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = ROOT / "vendor/ffcs/source.zip"
SCRIPT = ROOT / "scripts/prepare_ffcs_resources.sh"
LUT_NAME = "xh2s/provia.lutz"


@pytest.fixture(scope="module")
def expected_assets():
    return {
        name: digest
        for digest, name in (
            line.split() for line in (ROOT / "scripts/ffcs_native_SHA256SUMS").read_text().splitlines()
        )
    }


def prepare(archive, destination, *, check=True):
    return subprocess.run(
        ["bash", str(SCRIPT), str(archive), str(destination)],
        capture_output=True, text=True, check=check,
    )


def flip_first_byte(path):
    with path.open("r+b") as stream:
        first = stream.read(1)
        stream.seek(0)
        stream.write(bytes([first[0] ^ 1]))


@pytest.mark.parametrize("mutation", ["same-size-flip", "nonzero-truncation", "missing"])
def test_damaged_cached_lut_is_restored(tmp_path, expected_assets, mutation):
    destination = tmp_path / "FFCS"
    prepare(ARCHIVE, destination)
    resource = destination / LUT_NAME
    if mutation == "same-size-flip":
        flip_first_byte(resource)
    elif mutation == "nonzero-truncation":
        with resource.open("r+b") as stream:
            stream.truncate(resource.stat().st_size // 2)
    else:
        resource.unlink()

    prepare(ARCHIVE, destination)

    assert hashlib.sha256(resource.read_bytes()).hexdigest() == expected_assets[LUT_NAME]


def test_changed_archive_with_same_stat_is_rejected_without_changing_cached_luts(tmp_path, expected_assets):
    archive = tmp_path / "source.zip"
    shutil.copy2(ARCHIVE, archive)
    destination = tmp_path / "FFCS"
    prepare(archive, destination)
    before = archive.stat()
    flip_first_byte(archive)
    os.utime(archive, ns=(before.st_atime_ns, before.st_mtime_ns))

    result = prepare(archive, destination, check=False)

    assert result.returncode == 4
    assert "FFCS archive SHA256 mismatch" in result.stderr
    assert {
        name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
        for name in expected_assets
    } == expected_assets
