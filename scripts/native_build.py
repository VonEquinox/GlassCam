"""Shared SwiftPM build products for numerical tests and desktop runners."""
from functools import lru_cache
from pathlib import Path
import os
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'Packages/GlassCamKit'


def build_environment():
    env = os.environ.copy()
    if platform.system() == 'Darwin':
        env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    return env


def build_command(product=None, *, sanitize=False):
    command = ['swift', 'build', '-c', 'release', '--package-path', str(PACKAGE), '--build-system', 'native']
    if sanitize:
        command += ['--scratch-path', str(PACKAGE / '.build/native-sanitized'),
                    '--sanitize=address', '--sanitize=undefined']
    if product:
        command += ['--product', product]
    return command


@lru_cache(maxsize=None)
def binary_directory(*, sanitize=False):
    return Path(subprocess.check_output(build_command(sanitize=sanitize) + ['--show-bin-path'],
                                        env=build_environment(), text=True).strip())


@lru_cache(maxsize=None)
def build_product(product='GlassCamNative', *, sanitize=False):
    subprocess.run(build_command(product, sanitize=sanitize), env=build_environment(), check=True)
    directory = binary_directory(sanitize=sanitize)
    if product in ('GlassCamNative', 'GlassCamNativeTestSupport'):
        suffix = '.dylib' if platform.system() == 'Darwin' else '.so'
        return directory / ('lib' + product + suffix)
    return directory / product


def prepare_ffcs_resources(output):
    subprocess.run(['bash', str(ROOT / 'scripts/prepare_ffcs_resources.sh'),
                    str(ROOT / 'vendor/ffcs/source.zip'), str(output)], check=True)
    return Path(output)
