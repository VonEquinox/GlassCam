"""Load immutable native vectors after checking their recorded digest."""
import hashlib
import json

import numpy as np

from support.native import ROOT


def manifest(name):
    return json.loads((ROOT / "tests/fixtures/hncs" / name).read_text())


def vectors(metadata):
    path = ROOT / "tests/fixtures/hncs" / metadata["vectors"]
    expected = metadata.get("vectors_sha256", metadata.get("sha256"))
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f"Golden digest mismatch for {path.name}: {actual} != {expected}")
    with np.load(path, allow_pickle=False) as archive:
        return {key: archive[key] for key in archive.files}
