"""Build and run Swift journal persistence fixtures against production code."""
from pathlib import Path
import argparse
import subprocess

from native_build import build_environment, build_product, swift_native_flags

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--generate', type=Path)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    sources = ROOT / 'App/GlassCam'
    library = build_product()
    runner = ROOT / ('tests/support/JournalFixtureMain.swift' if args.generate
                     else 'tests/swift-legacy/journal_compatibility.swift')
    developer = Path(build_environment()['DEVELOPER_DIR'])
    frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
    macros = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
    testing_flags = [] if args.generate else [
        '-F', str(frameworks), '-load-plugin-library', str(macros),
        '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
    ]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O',
                    '-module-cache-path', str(work / 'modules'), *testing_flags, *swift_native_flags(library),
                    *map(str, sorted((sources / 'ImagingCore').rglob('*.swift'))),
                    *map(str, sorted((sources / 'Capture').glob('*.swift'))),
                    *map(str, sorted((sources / 'F5').glob('*.swift'))),
                    str(ROOT / 'tests/swift-legacy/F5Fixtures.swift'),
                    str(ROOT / 'tests/support/JournalFixtures.swift'), str(runner),
                    '-o', str(work / 'journal-fixtures')], env=build_environment(), check=True)
    if args.generate:
        arguments = [str(args.generate.resolve()), str(work / 'generated')]
    else:
        arguments = []
    environment = build_environment() | {
        'GLASSCAM_JOURNAL_FIXTURES': str(ROOT / 'tests/fixtures/journal'),
        'GLASSCAM_JOURNAL_WORK': str(work / 'tests'),
    }
    subprocess.run([str(work / 'journal-fixtures'), *arguments], env=environment, check=True)


if __name__ == '__main__':
    main()
