#!/usr/bin/env python3
"""Verify additive FFCS effect switches, legacy bytes and C ABI memory safety.

The recorded pre-switch hashes are immutable verification fixtures, captured
from the original constructor and APIs before editing core/ffcs.cpp. This tool
never regenerates them. Linux host evidence does not establish Apple runtime
behavior or cross-platform bit identity.
"""
import argparse
import ctypes as c
import hashlib
import json
import os
import platform
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'reference_ffcs/implementation/ffcs/data/xh2s'
FLAGS = ['-std=c++17', '-fno-fast-math', '-ffp-contract=off', '-pthread']


def legacy_snapshot(library):
    lib = c.CDLL(str(library))
    size, fp, bp = c.c_size_t, c.POINTER(c.c_float), c.POINTER(c.c_uint8)
    dp, vp, cp = c.POINTER(c.c_double), c.c_void_p, c.c_char_p
    callback = c.CFUNCTYPE(None, cp, dp, size, size, vp)
    lib.ffcs_create.argtypes = [cp, size, cp, size]
    lib.ffcs_create.restype = vp
    lib.ffcs_destroy.argtypes = [vp]
    lib.ffcs_process_linear_rgb.argtypes = [vp, fp, size, size, size, c.c_float,
        c.c_uint32, fp, size, bp, size, cp, size]
    lib.ffcs_process_encoded_double.argtypes = [vp, dp, size, size, size,
        c.c_uint32, dp, size, callback, vp, cp, size]
    digests = {}
    dimensions = [(1, 1), (1, 7), (9, 1), (7, 3), (131, 19)]
    for look in range(19):
        error = c.create_string_buffer(1024)
        ctx = lib.ffcs_create(str(ASSETS).encode(), look, error, len(error))
        assert ctx, error.value
        digest = hashlib.sha256()
        try:
            for w, h in dimensions:
                n = w * h * 3
                data = (c.c_float * n)(*[((i * 3919 + look * 13) % 8191) / 6000 - .1 for i in range(n)])
                data[0], data[1], data[2] = 0, .0031308, 1
                out = (c.c_float * n)()
                rgba = (c.c_uint8 * (w * h * 4))()
                for ev, seed in [(-2, 0), (.7, 37), (2, 0xffffffff)]:
                    assert lib.ffcs_process_linear_rgb(ctx, data, n, w, h, ev, seed,
                        out, n, rgba, len(rgba), error, len(error)), error.value
                    digest.update(bytes(out)); digest.update(bytes(rgba))
                encoded = (c.c_double * n)(*data)
                encoded_out = (c.c_double * n)()
                @callback
                def record(stage, values, width, height, user):
                    digest.update(stage)
                    digest.update(c.string_at(values, width * height * 3 * c.sizeof(c.c_double)))
                assert lib.ffcs_process_encoded_double(ctx, encoded, n, w, h,
                    0xffffffff, encoded_out, n, record, None, error, len(error)), error.value
                digest.update(bytes(encoded_out))
            digests[str(look)] = digest.hexdigest()
        finally:
            lib.ffcs_destroy(ctx)
    return {'looks': 19, 'linear_float_and_preview_cases': 285,
            'encoded_nine_stage_cases': 95, 'dimensions_width_height': dimensions,
            'sha256_per_look': digests}


def run(sanitize=False):
    report = {'status': 'pass', 'platform': platform.platform(),
              'compiler': subprocess.check_output(['g++', '--version'], text=True).splitlines()[0]}
    fixture_path = ROOT / 'validation/ffcs-effect-defaults-before.json'
    fixture = json.loads(fixture_path.read_text())
    with tempfile.TemporaryDirectory(prefix='ffcs-effect-switches-') as temp:
        temp = Path(temp)
        library = temp / 'libffcs_effect_switches.so'
        shared_command = ['g++', *FLAGS, '-O3', '-shared', '-fPIC',
                          str(ROOT / 'core/ffcs.cpp'), '-lz', '-o', str(library)]
        subprocess.run(shared_command, check=True)
        current = legacy_snapshot(library)
        assert current['sha256_per_look'] == fixture['snapshot']['sha256_per_look'], 'Default FFCS bytes changed'
        report['legacy_prechange_bytes'] = dict(current, bit_exact=True,
            original_source_sha256=fixture['original_source_sha256'],
            fixture_sha256=hashlib.sha256(fixture_path.read_bytes()).hexdigest())
        for label, extra_flags in [('optimized', ['-O3'])] + ([('asan_ubsan', [
                '-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'])] if sanitize else []):
            binary = temp / label
            command = ['g++', *FLAGS, *extra_flags, '-Wall', '-Wextra', '-Wpedantic',
                       str(ROOT / 'tests/ffcs_effect_switches_test.cpp'), '-lz', '-o', str(binary)]
            subprocess.run(command, check=True)
            env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:halt_on_error=1',
                       UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
            result = subprocess.run([str(binary), str(ASSETS)],
                                    capture_output=True, text=True, env=env)
            if result.returncode:
                raise RuntimeError(f'{label} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
            report[label] = dict(json.loads(result.stdout), compile_command=command,
                                 sanitizer_stderr=result.stderr)
        report['sanitizers_requested'] = sanitize
        report['leak_sanitizer'] = 'not run successfully: sandbox ptrace incompatibility'
    report['current_source_sha256'] = hashlib.sha256((ROOT / 'core/ffcs.cpp').read_bytes()).hexdigest()
    report['limitations'] = ['Linux host-only numerical and sanitizer evidence.',
        'No iPhone compile/runtime, UI, HEIF export, latency, or memory claim.',
        'All existing FFCS looks have positive grain and sharpness; zero-coefficient behavior is tested with private context copies.',
        'The strip halo contract stays unchanged with sharpening disabled.',
        'LeakSanitizer is disabled because this sandbox reports that it cannot run under ptrace; AddressSanitizer and UndefinedBehaviorSanitizer remain enabled.']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT / 'validation/ffcs-effect-switches.json')
    args = parser.parse_args()
    report = run(args.sanitize)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
