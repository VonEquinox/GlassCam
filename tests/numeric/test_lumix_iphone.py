"""Production photographic adapter outputs and frozen RGB48 vectors."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import ctypes as c
from dataclasses import dataclass
import json
import zipfile

import numpy as np
import pytest

from prepare_lumix_resources import prepare
from support.native import ROOT

VECTOR_ARCHIVE = ROOT / "tests/fixtures/lumix/native-full-vectors.zip"
with zipfile.ZipFile(VECTOR_ARCHIVE) as archive:
    VECTOR_NAMES = [name for name in archive.namelist() if name.endswith(".rgb16")]

# Preserve the existing bounds: native integer LUTs have small local reversals,
# while wraparound creates much larger discontinuities or lost endpoints.
MAX_COLOR_STEP = 0.025
MIN_LUMA_STEP = -0.002
MAX_BLACK_ENDPOINT = 0.005
MIN_WHITE_ENDPOINT = 0.95
OUTPUT_SENTINEL = -99


@dataclass(frozen=True)
class RenderCase:
    kind: str
    look: int = 0
    kelvin: int = 6500
    contrast: int = 10
    saturation: int = 10
    iso: int = 100
    ev: int = 0
    chunk: int = -1

    @property
    def label(self):
        return f"{self.kind}-look{self.look}-c{self.contrast}-s{self.saturation}-iso{self.iso}-ev{self.ev}-chunk{self.chunk}"


SATURATED = [RenderCase("saturated", look=look, contrast=level, saturation=level)
             for look in range(16) for level in (0, 10, 20)]
GRAY = [RenderCase("gray", look=look) for look in range(16)]
ISO = [RenderCase("iso", iso=iso) for iso in (100, 50, 64, 80, 400)]
SIGNED = RenderCase("signed", look=1, kelvin=4000, contrast=20, saturation=20)
EXPOSED = RenderCase("signed", look=1, kelvin=4000, contrast=20, saturation=20, ev=1)
SCALED = RenderCase("scaled", look=1, kelvin=4000, contrast=20, saturation=20)
CHUNKS = [RenderCase("signed", look=1, kelvin=4000, contrast=20, saturation=20, chunk=i) for i in range(4)]
VALID_CASES = SATURATED + GRAY + ISO + [SIGNED, EXPOSED, SCALED] + CHUNKS


@pytest.fixture(scope="module")
def pipeline_assets(lumix_resources):
    return lumix_resources


@pytest.fixture(scope="module")
def iphone(native):
    native.lumix_create_pipeline.argtypes = [c.c_char_p, c.c_size_t, c.c_double,
        c.c_int, c.c_int, c.c_int, c.c_char_p, c.c_size_t]
    native.lumix_create_pipeline.restype = c.c_void_p
    native.lumix_process_rgb16.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t,
        c.c_double, c.c_double, c.c_int, c.c_void_p, c.c_char_p, c.c_size_t]
    native.lumix_process_iphone_rgba.argtypes = [c.c_void_p, c.c_void_p,
        c.c_size_t, c.c_size_t, c.c_double, c.c_void_p, c.c_size_t, c.c_char_p, c.c_size_t]
    return native


@contextmanager
def context(library, assets, case):
    error = c.create_string_buffer(1024)
    value = library.lumix_create_pipeline(str(assets).encode(), case.look, case.kelvin,
        case.contrast, case.saturation, case.iso, error, len(error))
    assert value, error.value
    try:
        yield value
    finally:
        library.lumix_destroy(value)


@pytest.fixture(scope="module")
def samples():
    ramp = np.linspace(0, 1, 4097, dtype=np.float32)
    signed = np.random.default_rng(69).uniform(-.25, 1, (4096, 3)).astype(np.float32)
    return {
        "saturated": np.concatenate([ramp[:, None] * color for color in np.eye(3, dtype=np.float32)]),
        "gray": np.repeat(ramp[:, None], 3, axis=1),
        "iso": np.random.default_rng(42).uniform(0, 1, (1024, 3)),
        "signed": signed,
        "scaled": signed * 2,
    }


def render(library, value, pixels, ev=0):
    pixels = np.ascontiguousarray(pixels, dtype=np.float32).reshape(-1, 3)
    output = np.empty((len(pixels), 4), dtype=np.float32)
    error = c.create_string_buffer(1024)
    status = library.lumix_process_iphone_rgba(value, pixels.ctypes.data, pixels.size,
        len(pixels), ev, output.ctypes.data, output.size, error, len(error))
    return status, output, error.value


@pytest.fixture(scope="module")
def rendered(iphone, pipeline_assets, samples, request):
    case = request.param
    source = samples[case.kind]
    if case.chunk >= 0:
        source = np.array_split(source, 4)[case.chunk]
    with context(iphone, pipeline_assets, case) as value:
        status, output, error = render(iphone, value, source, case.ev)
    assert status == 1, error
    return output


@pytest.mark.parametrize("rendered", VALID_CASES, indirect=True, ids=lambda case: case.label)
def test_successful_iphone_output_is_finite(rendered):
    assert np.isfinite(rendered).all()


@pytest.mark.parametrize("rendered", VALID_CASES, indirect=True, ids=lambda case: case.label)
def test_successful_iphone_output_stays_in_unit_interval(rendered):
    assert rendered.min() >= 0
    assert rendered.max() <= 1


@pytest.mark.parametrize("rendered", VALID_CASES, indirect=True, ids=lambda case: case.label)
def test_successful_iphone_output_has_opaque_alpha(rendered):
    np.testing.assert_array_equal(rendered[:, 3], 1)


@pytest.mark.parametrize("name", VECTOR_NAMES)
def test_original_rgb48_fixture_remains_bit_exact(iphone, pipeline_assets, name):
    manifest = json.loads((pipeline_assets / "pipeline-manifest.json").read_text())
    indices = {row["photoStyle"]: index for index, row in enumerate(manifest["looks"])}
    # Negative EV introduces a double hyphen in the frozen fixture filename.
    fields = name[:-6].replace("--", "-NEG").split("-")
    style, kelvin, contrast, saturation, iso, white = map(int, fields[:6])
    ev, space = float(fields[6].replace("NEG", "-")), int(fields[7])
    with zipfile.ZipFile(VECTOR_ARCHIVE) as archive:
        values = np.frombuffer(archive.read(name), dtype="<u2").reshape(-1, 6)
    source = np.ascontiguousarray(values[:, :3])
    output = np.empty_like(source)
    error = c.create_string_buffer(1024)
    case = RenderCase("rgb48", indices[style], kelvin, contrast, saturation, iso)
    with context(iphone, pipeline_assets, case) as value:
        status = iphone.lumix_process_rgb16(value, source.ctypes.data, len(source),
            white, ev, space, output.ctypes.data, error, len(error))

    assert status == 1, error.value
    np.testing.assert_array_equal(output, values[:, 3:])


@pytest.mark.parametrize("rendered", SATURATED, indirect=True, ids=lambda case: case.label)
def test_saturated_ramp_has_no_wraparound_discontinuity(rendered):
    steps = np.diff(rendered[:, :3].reshape(3, -1, 3), axis=1)

    assert np.abs(steps).max() < MAX_COLOR_STEP


@pytest.mark.parametrize("rendered", GRAY, indirect=True, ids=lambda case: case.label)
def test_gray_ramp_preserves_local_steps_and_endpoints(rendered):
    luma = rendered[:, :3] @ [.2126, .7152, .0722]

    assert np.diff(luma).min() >= MIN_LUMA_STEP
    assert rendered[0, :3].max() < MAX_BLACK_ENDPOINT
    assert rendered[-1, :3].min() > MIN_WHITE_ENDPOINT


@pytest.mark.parametrize("case", ISO[1:], ids=lambda case: case.label)
def test_iphone_iso_does_not_select_panasonic_sensor_compensation(iphone, pipeline_assets, samples, case):
    with context(iphone, pipeline_assets, ISO[0]) as baseline:
        expected_status, expected, expected_error = render(iphone, baseline, samples["iso"])
    assert expected_status == 1, expected_error
    with context(iphone, pipeline_assets, case) as value:
        status, actual, error = render(iphone, value, samples["iso"])

    assert status == 1, error
    np.testing.assert_array_equal(actual, expected)


def test_signed_gamut_concurrent_strips_preserve_full_output(iphone, pipeline_assets, samples):
    with context(iphone, pipeline_assets, SIGNED) as value:
        expected_status, expected, error = render(iphone, value, samples["signed"])
        assert expected_status == 1, error
        with ThreadPoolExecutor(4) as executor:
            results = list(executor.map(lambda pixels: render(iphone, value, pixels), np.array_split(samples["signed"], 4)))

    assert [result[0] for result in results] == [1, 1, 1, 1]
    np.testing.assert_array_equal(np.concatenate([result[1] for result in results]), expected)


def test_exposure_matches_scaling_signed_gamut_input(iphone, pipeline_assets, samples):
    with context(iphone, pipeline_assets, SIGNED) as value:
        scaled_status, scaled, error = render(iphone, value, samples["scaled"])
        assert scaled_status == 1, error

        status, exposed, error = render(iphone, value, samples["signed"], ev=1)

    assert status == 1, error
    np.testing.assert_array_equal(exposed, scaled)


@pytest.mark.parametrize("bad", [float("nan"), float("inf"), -float("inf")])
def test_nonfinite_input_is_rejected_before_writing(iphone, pipeline_assets, bad):
    source = np.array([[.2, .3, .4], [bad, 0, 0]], dtype=np.float32)
    output = np.full((2, 4), OUTPUT_SENTINEL, dtype=np.float32)
    error = c.create_string_buffer(1024)
    with context(iphone, pipeline_assets, RenderCase("invalid")) as value:
        status = iphone.lumix_process_iphone_rgba(value, source.ctypes.data, source.size,
            len(source), 0, output.ctypes.data, output.size, error, len(error))

    assert status == 0
    np.testing.assert_array_equal(output, OUTPUT_SENTINEL)
