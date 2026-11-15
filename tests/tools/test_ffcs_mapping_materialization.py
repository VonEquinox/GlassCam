import hashlib
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepare_ffcs_mapping.py"
ARCHIVE = ROOT / "vendor/ffcs/mapping.zip"


def prepare(output, archive=ARCHIVE):
    return subprocess.run([sys.executable, str(SCRIPT), "--archive", str(archive),
                           "--output", str(output)], capture_output=True, text=True)


def test_corrupt_cached_mapping_is_restored(tmp_path):
    output = tmp_path / "FFCS"
    assert prepare(output).returncode == 0
    resource = output / "xh2s/provia.ffcm"
    expected = hashlib.sha256(resource.read_bytes()).hexdigest()
    resource.write_bytes(b"damaged")

    result = prepare(output)

    assert result.returncode == 0
    assert hashlib.sha256(resource.read_bytes()).hexdigest() == expected


def test_changed_mapping_archive_is_rejected_with_existing_cache(tmp_path):
    output = tmp_path / "FFCS"
    assert prepare(output).returncode == 0
    resource = output / "xh2s/provia.ffcm"
    expected = resource.read_bytes()
    archive = tmp_path / "mapping.zip"
    shutil.copyfile(ARCHIVE, archive)
    with archive.open("r+b") as stream:
        stream.write(b"invalid")

    result = prepare(output, archive)

    assert result.returncode != 0
    assert resource.read_bytes() == expected
