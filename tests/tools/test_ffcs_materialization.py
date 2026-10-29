import hashlib
import importlib.util
import json
from pathlib import Path

import pytest


module = importlib.util.spec_from_file_location(
    "materialize_ffcs_reference", Path(__file__).resolve().parents[2] / "scripts/materialize_ffcs_reference.py"
)
materialization = importlib.util.module_from_spec(module)
module.loader.exec_module(materialization)


@pytest.fixture(scope="module")
def reference(tmp_path_factory):
    destination = tmp_path_factory.mktemp("ffcs-reference")
    materialization.materialize_reference(destination)
    return destination


def test_materialized_lut_retains_delivery_bytes(reference):
    manifest = json.loads((reference / "validation/delivery_manifest.json").read_text())
    name = "implementation/ffcs/data/xh2s/provia.lutz"
    expected = next(entry["sha256"] for entry in manifest["files"] if entry["path"] == name)

    actual = hashlib.sha256((reference / name).read_bytes()).hexdigest()

    assert actual == expected


@pytest.mark.parametrize("name", ["FIXES_20261013.md", "implementation/VALIDATION_STATUS.md",
    "implementation/tests/test_pipeline.py", "validation/pytest_output.txt",
    "implementation/tools/native_probe.cpp"])
def test_materialization_keeps_delivery_history_in_archive(reference, name):
    assert not (reference / name).exists()


def test_untrusted_archive_is_rejected_before_creating_output(tmp_path):
    archive = tmp_path / "untrusted.zip"
    archive.write_bytes(b"not the pinned FFCS delivery")
    destination = tmp_path / "reference"

    with pytest.raises(ValueError, match="FFCS archive SHA256 mismatch"):
        materialization.materialize_reference(destination, archive)

    assert not destination.exists()
