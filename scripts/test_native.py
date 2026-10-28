"""Run every native contract executable normally and with ASan/UBSan."""
import os
import subprocess

from native_build import PACKAGE, binary_directory, build_command, build_environment, prepare_ffcs_resources

CHECKS = (
    'hncs_smoke', 'hncs_spatial_smoke', 'hncs_parallel_sanitizer',
    'hncs_revision8_sanitizer', 'hncs_native_pipeline_sanitizer',
    'ffcs_smoke', 'ffcs_strip_sanitizer', 'ffcs_color_only_test',
    'ffcs_effect_switches_test', 'f5_core_tests',
)


def main():
    resources = prepare_ffcs_resources(PACKAGE / '.build/native-test-resources/FFCS')
    for sanitize in (False, True):
        env = build_environment()
        if sanitize:
            # Apple platforms do not implement LeakSanitizer.
            if os.uname().sysname == 'Darwin':
                env['ASAN_OPTIONS'] = 'detect_leaks=0' + (':' + env['ASAN_OPTIONS'] if env.get('ASAN_OPTIONS') else '')
            env['UBSAN_OPTIONS'] = 'halt_on_error=1:print_stacktrace=1'
        for name in CHECKS:
            subprocess.run([*build_command(sanitize=sanitize), "--product", name], env=env, check=True)
        directory = binary_directory(sanitize=sanitize)
        for name in CHECKS:
            print(f'{name}: {"ASan + UBSan" if sanitize else "release"}', flush=True)
            arguments = [str(resources / 'xh2s')] if name.startswith('ffcs_') else []
            subprocess.run([str(directory / name), *arguments], env=env, check=True)


if __name__ == '__main__':
    main()
