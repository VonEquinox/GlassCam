"""Standard preset output matches the pinned native gradation reference."""
import numpy as np
import pytest

from support import reference_runtime as r
from support.phocus_binary_reference import presets
from support.native import context, render

# Existing dense reference gate: Float32 output versus double-precision reference.
REFERENCE_TOLERANCE = 1e-7


@pytest.fixture(scope='module', params=['shaped-grid', 'negative-superwhite-random'])
def dense_pixels(request):
    if request.param == 'shaped-grid':
        grid = np.indices((65, 65, 65)).reshape(3, -1).T.astype(np.float64) / 64
        return np.ascontiguousarray(np.where(grid <= .04045, grid / 12.92, ((grid + .055) / 1.055)**2.4), dtype=np.float32)
    return np.random.default_rng(810132).uniform(-.05, 1.05, (200003, 3)).astype(np.float32)


@pytest.mark.parametrize('kelvin', [5500, 6500])
def test_dense_standard_gradation_matches_reference(native, reference_assets, dense_pixels, kelvin):
    source = r.experimental_adapter(dense_pixels, kelvin, reference_assets)
    codes = r.hncs_codes(source, kelvin, reference_assets, working_space='legacy')
    corrected, _ = presets.apply_post_curves(codes, 'standard')
    encoded = r.srgb_from_hncs(corrected, reference_assets, 'legacy')
    expected = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055)**2.4)

    with context(native, key='standard', kelvin=kelvin) as ctx:
        output_status, output = render(native, 'hncs_process_linear_rgba', ctx, dense_pixels)
        assert output_status == 0

    np.testing.assert_allclose(output[:, :3], expected, rtol=0, atol=REFERENCE_TOLERANCE)
    np.testing.assert_array_equal(output[:, 3], 1)
