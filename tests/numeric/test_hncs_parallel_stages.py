"""Production parallel stages preserve serial bits at scheduling boundaries."""
import ctypes as c

import numpy as np
import pytest

STAGES = [("hncs_process_linear_rgba", 4), ("hncs_process_preset_work_float", 3),
    ("hncs_finish_preset_work_linear", 4), ("hncs_process_phocus_work_float", 3),
    ("hncs_finish_phocus_work_linear", 4), ("hncs_process_phocus_linear_rgba", 4)]
PRESETS = ["standard", "nature", "lighten", "extra-contrast", "high",
    "film-grain-artistic", "square-crop", "tungsten", "saturated", "grayscale-red-filter"]
COUNTS = [1, 32767, 65535, 65536, 65539, 131079]


@pytest.fixture(scope="module")
def stages(native):
    native.hncs_create_preset_whitepoint.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int]
    native.hncs_create_preset_whitepoint.restype = c.c_void_p
    for name, _ in STAGES:
        getattr(native, name).argtypes = [c.c_void_p] * 3 + [c.c_size_t]
        getattr(native, name + "_parallel").argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_uint]
    return native


@pytest.fixture(scope="module")
def pixels():
    rng = np.random.default_rng(17102026)
    source = rng.uniform(-0.2, 1.2, (131079, 3)).astype(np.float32)
    source[:8] = [[0, 0, 0], [1, 1, 1], [-1, -1, -1], [2, 2, 2],
                  [1, 0, 0], [0, 1, 0], [0, 0, 1], [.5, .5, .5]]
    return source


@pytest.fixture(scope="module", params=list(enumerate(PRESETS)), ids=lambda item: item[1])
def stage_context(stages, request):
    index, preset = request.param
    context = stages.hncs_create_preset_whitepoint([-2, 0, 2][index % 3], .33943, .35259,
        0, index % 2, (index // 2) % 2, 4, 2, preset.encode(), index % 2)
    assert context
    try:
        yield context
    finally:
        stages.hncs_destroy(context)


@pytest.mark.parametrize("name,channels", STAGES, ids=[name for name, _ in STAGES])
@pytest.mark.parametrize("count", COUNTS)
@pytest.mark.parametrize("workers", [1, 2, 3, 4])
def test_parallel_stage_boundary_preserves_serial_bits(stages, pixels, stage_context, name, channels, count, workers):
    expected = np.zeros((count, channels), np.float32)
    serial_status = getattr(stages, name)(stage_context, pixels.ctypes.data, expected.ctypes.data, count)
    assert serial_status == 0
    actual = np.full_like(expected, -100)

    status = getattr(stages, name + "_parallel")(
        stage_context, pixels.ctypes.data, actual.ctypes.data, count, workers)

    assert status == 0
    np.testing.assert_array_equal(actual.view(np.uint32), expected.view(np.uint32))


@pytest.fixture(scope="module")
def validation_context(stages):
    context = stages.hncs_create_preset_whitepoint(0, .3127, .329, 0, 0, 0, 4, 2, b"nature", 1)
    assert context
    try:
        yield context
    finally:
        stages.hncs_destroy(context)


@pytest.mark.parametrize("name,channels", STAGES, ids=[name for name, _ in STAGES])
@pytest.mark.parametrize("workers", [1, 2, 3, 4])
@pytest.mark.parametrize("case,expected", [("empty", 0), ("null-context", -1), ("null-input", -1),
    ("null-output", -1), ("overflow-count", -1), ("nan", -1), ("infinity", -1)])
def test_parallel_stage_invalid_input_returns_expected_status(stages, validation_context, name, channels, workers, case, expected):
    source = np.zeros((65539, 3), np.float32)
    output = np.zeros((65539, 4), np.float32)
    arguments = [validation_context, source.ctypes.data, output.ctypes.data, 1, workers]
    if case == "empty":
        arguments[1:4] = [None, None, 0]
    elif case == "null-context":
        arguments[:4] = [None, None, None, 0]
    elif case == "null-input":
        arguments[1] = None
    elif case == "null-output":
        arguments[2] = None
    elif case == "overflow-count":
        arguments[3] = 2**64 - 1
    else:
        source[-1, 2] = np.nan if case == "nan" else np.inf
        arguments[3] = len(source)

    actual = getattr(stages, name + "_parallel")(*arguments)

    assert actual == expected


@pytest.mark.parametrize("name,channels", STAGES, ids=[name for name, _ in STAGES])
@pytest.mark.parametrize("workers", [0, 5])
def test_parallel_stage_invalid_worker_count_is_rejected(stages, validation_context, name, channels, workers):
    status = getattr(stages, name + "_parallel")(validation_context, None, None, 0, workers)

    assert status == -1
