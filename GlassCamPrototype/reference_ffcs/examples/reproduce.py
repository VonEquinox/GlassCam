"""Reproduce FFCS numerical stages without any external input image."""
from pathlib import Path
from io import BytesIO
import argparse
import json
from unittest.mock import patch
from PIL import Image
from ffcs import FFCS, PipelineConfig
from ffcs.io import load_pixels
from ffcs.raw import RawSensor, develop_raf

ROOT = Path(__file__).resolve().parents[1]


def fixtures(directory):
    image = Image.new('RGB', (6, 4))
    image.putdata([(r, g, b) for b in (0, 64, 192, 255)
                   for r, g in ((0, 0), (255, 0), (0, 255), (128, 96), (32, 200), (255, 255))])
    image.save(directory / 'input.png')
    cube = directory / 'identity.cube'
    cube.write_text('LUT_3D_SIZE 2\n' + '\n'.join(
        f'{r} {g} {b}' for b in (0, 1) for g in (0, 1) for r in (0, 1)) + '\n')
    payload = BytesIO()
    image.save(payload, format='JPEG', quality=100)
    raf = directory / 'preview_fixture.raf'
    raf.write_bytes(b'FUJIFILMCCD-RAW' + payload.getvalue())
    return image, cube, raf


def cases(directory):
    image, cube, raf = fixtures(directory)
    configs = {
        'xh2s_provia': PipelineConfig(camera='XH2S'),
        'xa3_chrome': PipelineConfig(camera='XA3', simulation='CC'),
        'gfx100s_acros_ye': PipelineConfig(camera='GFX100S', simulation='ACROS', filter_colour='Ye'),
        'xh2s_sepia': PipelineConfig(camera='XH2S', simulation='SEPIA'),
        'missing_table_reala': PipelineConfig(camera='XH2S', simulation='REALA ACE'),
        'analytic_classic_neg': PipelineConfig(camera='XH2S', simulation='NC', use_reference_luts=False),
        'analytic_mono_r': PipelineConfig(simulation='MONOCHROME', filter_colour='R', use_reference_luts=False),
        'cube_encoded_sigma': PipelineConfig(camera='XH2S', lut_path=cube, lut_domain='encoded', sigma=1.6),
        'cube_linear': PipelineConfig(camera='XH2S', lut_path=cube, lut_domain='linear'),
        'adobergb_seed': PipelineConfig(camera='XH2S', output_space='AdobeRGB', seed=37),
        'linear_input': PipelineConfig(input_is_linear=True, use_reference_luts=False),
    }
    results = {name: FFCS(cfg).apply(image) for name, cfg in configs.items()}
    results['preview_raf'] = FFCS(PipelineConfig(camera='XA3', use_reference_luts=False)).apply_path(raf)
    # Synthetic, explicitly labelled sensor fixture; not a real RAF decoder test.
    sensor = RawSensor(
        [[float(100 + y*240 + x*180) for x in range(6)] for y in range(4)],
        (('R', 'G'), ('G', 'B')), (64, 64, 64), 4095, (2, 1, 1.5),
        {'fixture': 'synthetic-sensor', 'pattern': (('R', 'G'), ('G', 'B'))},
    )
    rawmeta = {'decoder': 'rawpy-sensor', 'demosaic_algorithm': 'bilinear-cfa'}
    with patch('ffcs.raw.load_raf', return_value=(sensor, rawmeta)):
        developed = develop_raf('synthetic.raf', 'XA3')
    for linear in (False, True):
        results['synthetic_sensor_' + str(linear).lower()] = FFCS(PipelineConfig(
            camera='XA3', input_is_linear=linear, use_reference_luts=False,
        )).apply(developed.image, input_pixels=developed.stage_pixels['resize_lanczos'],
                 raw_stages=developed.stages, raw_stage_pixels=developed.stage_pixels,
                 raw_metadata=developed.metadata)
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--record-baseline', action='store_true', help='Explicitly replace baseline for a new implementation version')
    args = parser.parse_args()
    directory = ROOT / 'examples/generated'
    directory.mkdir(parents=True, exist_ok=True)
    results = cases(directory)
    snapshot = {name: result.stage_pixels for name, result in results.items()}
    baseline_path = ROOT / 'validation/baseline_pixels.json'
    if args.record_baseline:
        baseline_path.write_text(json.dumps(snapshot, indent=2) + '\n')
    expected = json.loads(baseline_path.read_text())
    if set(snapshot) != set(expected):
        raise AssertionError('Fixture case names differ')
    max_error = 0.0
    for name, stages in snapshot.items():
        if set(stages) != set(expected[name]):
            raise AssertionError(f'{name}: stage names differ')
        for stage, pixels in stages.items():
            reference = expected[name][stage]
            if len(pixels) != len(reference) or any(len(a) != len(b) for a, b in zip(pixels, reference)):
                raise AssertionError(f'{name}/{stage}: shape differs')
            for y, row in enumerate(pixels):
                for x, rgb in enumerate(row):
                    error = max(abs(rgb[c] - reference[y][x][c]) for c in range(3))
                    max_error = max(max_error, error)
                    if error > 1e-12:
                        raise AssertionError(f'{name}/{stage}/{y}/{x}: error {error}')
        result = results[name]
        path = directory / f'{name}.tif'
        result.save(path)
        loaded = load_pixels(path)
        for row, restored in zip(result.pixels, loaded):
            for a, b in zip(row, restored):
                if max(abs(a[c]-b[c]) for c in range(3)) > 0.5/65535 + 1e-12:
                    raise AssertionError(f'{name}: TIFF16 quantization differs')
    results['xh2s_provia'].save_stages(directory / 'xh2s_provia_stages')
    results['preview_raf'].save_stages(directory / 'preview_raf_stages')
    report = {'status': 'pass', 'cases': len(results), 'stage_maps': sum(len(r.stages) for r in results.values()),
              'maximum_absolute_stage_error': max_error, 'stage_tolerance': 1e-12,
              'tiff16_roundtrip': 'pass', 'synthetic_sensor_is_real_raf_test': False}
    (directory / 'reproduction_report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
