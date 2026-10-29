"""Independent colour-domain vectors and HDR spatial behavior."""
from contextlib import contextmanager
import ctypes as c

import numpy as np
import pytest

from support.native import context

# Preserve the published-matrix Float32 conversion and HDR ratio budgets.
PRIMARY_RTOL = 2e-6
PRIMARY_ATOL = 3e-7
HDR_RATIO_RTOL = 2e-6
FRAME_SCALE = 5.8829245141
PRIMARY_MATRICES = (np.array([[.64912, .18858, .12649], [.29886, .65745, .04369], [.00464, .04303, .77724]]),
    np.array([[.87226, .07622, .01574], [.28112, .69989, .01899], [0., 0., .82521]]))


@pytest.fixture(scope='module')
def hdr(native):
    native.hncs_create_preset_whitepoint_with_policy.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int, c.c_int]
    native.hncs_create_preset_whitepoint_with_policy.restype = c.c_void_p
    native.hncs_apple_hdr_work_scale.argtypes = [c.c_double]
    native.hncs_apple_hdr_work_scale.restype = c.c_double
    native.hncs_clone_with_apple_hdr_work_scale.argtypes = [c.c_void_p, c.c_double]
    native.hncs_clone_with_apple_hdr_work_scale.restype = c.c_void_p
    native.hncs_process_apple_hdr_work_float_parallel.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_uint]
    native.hncs_finish_apple_hdr_work_linear_parallel.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_double, c.c_uint]
    native.hncs_prepare_apple_hdr_spatial.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p,
        c.c_int, c.c_int, c.c_double, c.c_double]
    native.hncs_prepare_apple_hdr_spatial_file.argtypes = [c.c_char_p, c.c_size_t, c.c_size_t, c.c_char_p,
        c.c_int, c.c_int, c.c_double, c.c_double, c.c_char_p, c.c_void_p, c.c_void_p]
    return native


@contextmanager
def photo_context(lib, lstar=0):
    ctx = lib.hncs_create_preset_whitepoint_with_policy(0., .3127, .3290, 0., lstar, 0, 4, 2, b'standard', 1, 1)
    assert ctx
    try:
        yield ctx
    finally:
        lib.hncs_destroy(ctx)


def prepare_work(lib, ctx, source, workers=1):
    source = np.ascontiguousarray(source, dtype=np.float32)
    work = np.empty_like(source)
    status = lib.hncs_process_apple_hdr_work_float_parallel(ctx, source.ctypes.data, work.ctypes.data, source.size // 3, workers)
    return status, work


def finish(lib, ctx, work, scale, workers=1):
    work = np.ascontiguousarray(work, dtype=np.float32)
    output = np.empty((*work.shape[:-1], 4), np.float32)
    status = lib.hncs_finish_apple_hdr_work_linear_parallel(ctx, work.ctypes.data, output.ctypes.data, work.size // 3, scale, workers)
    return status, output


@pytest.fixture(scope='module', params=(0, 1), ids=('legacy', 'lstar'))
def primaries(hdr, request):
    # Independent published working-primary matrices and Bradford D65 CAT.
    matrix = PRIMARY_MATRICES[request.param]
    bradford = np.array([[.8951, .2664, -.1614], [-.7502, 1.7135, .0367], [.0389, -.0685, 1.0296]])
    xyz_to_srgb = np.array([[3.2404542, -1.5371385, -.4985314], [-.969266, 1.8760108, .041556], [.0556434, -.2040259, 1.0572252]])
    cat = np.linalg.inv(bradford) @ np.diag((bradford @ [.95047, 1., 1.08883]) / (bradford @ matrix.sum(axis=1))) @ bradford
    expected = (xyz_to_srgb @ cat @ matrix).T
    with context(hdr, kelvin=5500, lstar=request.param) as ctx:
        status, output = finish(hdr, ctx, np.eye(3, dtype=np.float32), 1.)
    return status, output, expected


def test_working_primaries_match_published_conversion(primaries):
    status, actual, expected = primaries
    assert status == 0
    np.testing.assert_allclose(actual[:, :3], expected, rtol=PRIMARY_RTOL, atol=PRIMARY_ATOL)


def test_working_primaries_survive_as_signed_extended_srgb(primaries):
    _, actual, _ = primaries
    assert float(actual[:, :3].min()) < -.01
    assert float(actual[:, :3].max()) > 1.
    np.testing.assert_array_equal(actual[:, 3], 1.)


@pytest.mark.parametrize('lstar', [0, 1])
def test_hdr_magnitude_is_present_before_spatial_processing(hdr, lstar):
    with photo_context(hdr, lstar) as ctx:
        status, work = prepare_work(hdr, ctx, [[2., 2., 2.], [4., 4., 4.]])
    if lstar:
        linear = np.where(work <= .08, work / (24389. / 2700.), ((work + .16) / 1.16) ** 3)
    else:
        linear = work.astype(np.float64) ** (563. / 256.)

    assert status == 0
    np.testing.assert_array_less(work[0], work[1])
    np.testing.assert_allclose(linear[1] / linear[0], 2., rtol=HDR_RATIO_RTOL)


@pytest.fixture(scope='module')
def bright_structure(hdr):
    work = np.full((9, 33, 3), 2., np.float32)
    work[:, 15:18] = 2.1
    scale = hdr.hncs_apple_hdr_work_scale(float(work.max()))
    off, on = work.copy(), work.copy()
    statuses = [hdr.hncs_prepare_apple_hdr_spatial(image.ctypes.data, 33, 9, b'standard', 0, sharp, 1.5, scale)
        for sharp, image in ((0, off), (1, on))]
    return work, scale, off, on, statuses


def test_hdr_scale_and_disabled_sharpness_preserve_normalized_work(bright_structure):
    work, scale, off, _, statuses = bright_structure
    assert scale == FRAME_SCALE
    assert statuses[0] == 0
    np.testing.assert_array_equal(off, (work.astype(np.float64) / scale).astype(np.float32))


def test_sharpness_operates_on_bright_neutral_structure(bright_structure):
    _, _, off, on, statuses = bright_structure
    assert statuses[1] == 0
    assert float(on[4, 15, 0]) > float(off[4, 15, 0]) + 1e-4
    assert float(on[4, 14, 0]) < float(off[4, 14, 0]) - 1e-4


def test_hdr_sharpness_preserves_neutral_channels_and_finite_bounds(bright_structure):
    on = bright_structure[3]
    np.testing.assert_array_equal(on[:, :, 0], on[:, :, 1])
    np.testing.assert_array_equal(on[:, :, 1], on[:, :, 2])
    assert np.isfinite(on).all()
    assert ((on >= 0) & (on <= 1)).all()


@pytest.fixture(scope='module')
def frame(hdr, tmp_path_factory):
    h, w = 260, 257
    source = np.random.default_rng(19).uniform(0, 8, (h, w, 3)).astype(np.float32)
    with photo_context(hdr) as ctx:
        work_status, whole = prepare_work(hdr, ctx, source, workers=4)
        scale = hdr.hncs_apple_hdr_work_scale(float(whole.max()))
        packed = whole.copy()
        packed_status = hdr.hncs_prepare_apple_hdr_spatial(packed.ctypes.data, w, h, b'standard', 0, 1, 1.5, scale)
        temporary = tmp_path_factory.mktemp('hdr-domain')
        path = temporary / 'frame.rgbf'
        whole.tofile(path)
        file_status = hdr.hncs_prepare_apple_hdr_spatial_file(str(path).encode(), w, h, b'standard', 0, 1, 1.5, scale,
            str(temporary).encode(), None, None)
        disk = np.fromfile(path, np.float32).reshape(whole.shape)
        output_context = hdr.hncs_clone_with_apple_hdr_work_scale(ctx, scale)
        assert output_context
        try:
            finish_status, complete = finish(hdr, output_context, packed, scale, workers=4)
            yield dict(ctx=ctx, source=source, whole=whole, scale=scale, packed=packed, disk=disk,
                output_context=output_context, complete=complete, work_status=work_status,
                packed_status=packed_status, file_status=file_status, finish_status=finish_status)
        finally:
            hdr.hncs_destroy(output_context)


@pytest.mark.parametrize('rows', [17, 64, 129])
def test_one_frame_scale_matches_work_strip_partitions(hdr, frame, rows):
    results = [prepare_work(hdr, frame['ctx'], frame['source'][y:y + rows])
        for y in range(0, len(frame['source']), rows)]
    statuses = [status for status, _ in results]
    partitioned = np.concatenate([output for _, output in results])

    assert frame['work_status'] == 0
    assert statuses == [0] * len(results)
    np.testing.assert_array_equal(partitioned, frame['whole'])


def test_one_frame_scale_matches_memory_and_file_storage(frame):
    assert frame['packed_status'] == 0
    assert frame['file_status'] == 0
    np.testing.assert_array_equal(frame['disk'], frame['packed'])


@pytest.mark.parametrize('rows', [31, 64])
def test_one_frame_scale_matches_finish_strip_partitions(hdr, frame, rows):
    results = [finish(hdr, frame['output_context'], frame['packed'][y:y + rows], frame['scale'])
        for y in range(0, len(frame['packed']), rows)]
    statuses = [status for status, _ in results]
    partitioned = np.concatenate([output for _, output in results])

    assert frame['finish_status'] == 0
    assert statuses == [0] * len(results)
    np.testing.assert_array_equal(partitioned, frame['complete'])


@pytest.mark.parametrize('value', [-1., 65., np.inf, np.nan])
def test_invalid_hdr_work_maximum_is_rejected(hdr, value):
    assert hdr.hncs_apple_hdr_work_scale(value) == -1.


@pytest.mark.parametrize('value', [0., .5, 65., np.nan])
def test_invalid_hdr_scale_rejects_clone(hdr, value):
    with photo_context(hdr) as ctx:
        clone = hdr.hncs_clone_with_apple_hdr_work_scale(ctx, value)
        if clone:
            hdr.hncs_destroy(clone)
    assert not clone


def test_missing_hdr_scale_binding_rejects_finish(hdr):
    work, output = np.zeros((2, 3), np.float32), np.zeros((2, 4), np.float32)
    with photo_context(hdr) as ctx:
        status = hdr.hncs_finish_apple_hdr_work_linear_parallel(ctx, work.ctypes.data, output.ctypes.data, 2, FRAME_SCALE, 1)
    assert status == -1


def test_invalid_hdr_spatial_scale_is_rejected(hdr):
    work = np.zeros((2, 3), np.float32)
    status = hdr.hncs_prepare_apple_hdr_spatial(work.ctypes.data, 2, 1, b'standard', 0, 0, 0., .5)
    assert status == -1
