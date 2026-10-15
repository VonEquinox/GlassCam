"""Portable row-storage model and Swift spatial-stage integration contracts.

Numerical grain/USM parity is tested by the native-core suite. These checks cover
how the app keeps whole-image spatial coordinates while streaming CI strips;
they do not execute Foundation FileHandle or an Apple encoder.
"""
import io
from pathlib import Path
import random
import re
import struct
import unittest

from test_hncs_revision8_source import body, compact, source


def write_top_down(file, rgb, width, height, origin, rows):
    if origin < 0 or rows <= 0 or origin > height - rows or len(rgb) != width * rows * 3:
        raise ValueError('invalid strip')
    file.seek(origin * width * 12)
    file.write(struct.pack('<' + 'f' * len(rgb), *rgb))


def read_top_down(file, width, height, origin, rows):
    if origin < 0 or rows <= 0 or origin > height - rows:
        raise ValueError('invalid strip')
    file.seek(origin * width * 12)
    data = file.read(width * rows * 12)
    if len(data) != width * rows * 12:
        raise ValueError('incomplete strip')
    return list(struct.unpack('<' + 'f' * (width * rows * 3), data))


class SpatialRowStorageModelTests(unittest.TestCase):
    def test_every_strip_partition_produces_one_identical_top_down_work_image(self):
        for width, height in [(1, 1), (1, 65), (3, 7), (4, 64), (5, 65), (3, 129)]:
            full = [float(i) for i in range(width * height * 3)]
            expected = b''.join(struct.pack('<' + 'f' * width * 3,
                                           *full[y * width * 3:(y + 1) * width * 3])
                                for y in range(height))
            for strip in [1, 2, 3, 16, 64, height]:
                work = io.BytesIO()
                for origin in range(0, height, strip):
                    rows = min(strip, height - origin)
                    write_top_down(work, full[origin * width * 3:(origin + rows) * width * 3],
                                    width, height, origin, rows)
                self.assertEqual(work.getvalue(), expected)
                self.assertEqual(len(work.getvalue()), width * height * 12)

    def test_different_write_and_read_partitions_preserve_each_pixel_and_channel(self):
        rng = random.Random(8)
        for width, height in [(1, 1), (1, 67), (7, 1), (5, 13), (3, 127)]:
            pixels = [float(i) for i in range(width * height * 3)]
            work = io.BytesIO()
            origin = 0
            while origin < height:
                rows = min(rng.randrange(1, 65), height - origin)
                write_top_down(work, pixels[origin * width * 3:(origin + rows) * width * 3],
                                width, height, origin, rows)
                origin += rows
            output = []
            origin = 0
            while origin < height:
                rows = min(rng.randrange(1, 65), height - origin)
                output.extend(read_top_down(work, width, height, origin, rows))
                origin += rows
            self.assertEqual(output, pixels)

    def test_spatial_output_top_down_coordinates_survive_partitioned_read(self):
        width, height = 3, 67
        # A stand-in whole-image spatial operation identifies each top-left
        # coordinate. It would expose accidental per-strip coordinate resets.
        top_down = [float(10000 * y + 100 * x + channel)
                    for y in range(height) for x in range(width) for channel in range(3)]
        work = io.BytesIO(struct.pack('<' + 'f' * len(top_down), *top_down))
        actual = []
        for origin in range(0, height, 64):
            actual.extend(read_top_down(work, width, height, origin, min(64, height - origin)))
        self.assertEqual(actual, top_down)

    def test_invalid_or_short_strips_fail_instead_of_leaking_partial_image(self):
        for origin, rows in [(-1, 1), (0, 0), (0, -1), (3, 2), (5, 1)]:
            with self.subTest(origin=origin, rows=rows):
                with self.assertRaises(ValueError):
                    write_top_down(io.BytesIO(), [], 3, 4, origin, rows)
                with self.assertRaises(ValueError):
                    read_top_down(io.BytesIO(), 3, 4, origin, rows)
        with self.assertRaises(ValueError):
            write_top_down(io.BytesIO(), [0] * 8, 3, 4, 0, 1)
        with self.assertRaisesRegex(ValueError, 'incomplete strip'):
            read_top_down(io.BytesIO(b'\0' * 35), 3, 4, 3, 1)


class Revision8SpatialIntegrationSourceContracts(unittest.TestCase):
    def assertOrdered(self, text, *items):
        offset = 0
        for item in items:
            index = text.find(item, offset)
            self.assertGreaterEqual(index, 0, f'{item!r} absent after offset {offset}')
            offset = index + len(item)

    def test_native_sources_are_built_once_with_strict_float_contract_on_both_targets(self):
        root = Path(__file__).resolve().parents[1]
        project = (root / 'ios/GlassCam.xcodeproj/project.pbxproj').read_text()
        cmake = (root / 'core/CMakeLists.txt').read_text()
        native = re.search(r'add_library\(glasscam_hncs STATIC ([^)]+)\)', cmake).group(1).split()
        phase = re.search(r'isa = PBXSourcesBuildPhase;[^\n]*files = \(([^)]*)\)', project).group(1).split(',')
        phase = [value.strip() for value in phase]
        for filename in ['hncs.cpp', 'hncs_spatial.cpp', 'hncs_numpy_rng.cpp']:
            with self.subTest(filename=filename):
                self.assertEqual(native.count(filename), 1)
                references = re.findall(r'(\w+) = \{isa = PBXFileReference;[^\n]*path = ' + re.escape(filename) + r';', project)
                self.assertEqual(len(references), 1)
                builds = re.findall(r'(\w+) = \{isa = PBXBuildFile; fileRef = ' + references[0] + r';[^\n]*COMPILER_FLAGS = "([^"]+)"', project)
                self.assertEqual(len(builds), 1)
                build_id, flags = builds[0]
                self.assertEqual(phase.count(build_id), 1)
                self.assertIn('-fno-fast-math', flags.split())
                self.assertIn('-ffp-contract=off', flags.split())
                self.assertNotIn('-ffast-math', flags.split())
                self.assertNotIn('-Ofast', flags.split())
        options = re.findall(r'target_compile_options\(glasscam_hncs PRIVATE ([^)]+)\)', cmake)
        self.assertTrue(any('-fno-fast-math' in value and '-ffp-contract=off' in value for value in options))
        self.assertTrue(any('/fp:strict' in value for value in options))
        bridge = (root / 'ios/GlassCam/GlassCam-Bridging-Header.h').read_text()
        self.assertEqual(bridge.count('#include "hncs_spatial.h"'), 1)
        self.assertEqual(bridge.count('#include "hncs_c.h"'), 1)

    def test_spatial_work_file_matches_model_byte_offsets_and_releases_scratch(self):
        file = body(source('SourceImageStore.swift'), 'final class HNCSPresetWorkFile')
        self.assertIn('width <= Int.max / 12 / height', file)
        write = body(file, 'func writeTopDownRows(')
        self.assertOrdered(write, 'originY <= height - rows', 'rgb.count == width * rows * 3',
                           'originY * width * 12', 'handle.write(contentsOf: Data($0))')
        read = body(file, 'func readTopDownRows(')
        self.assertOrdered(read, 'originY * width * 12', 'data.count == count', 'data.copyBytes(to: $0)')
        self.assertNotIn('reversed()', write + read)
        prepare = body(file, 'func prepareForSpatialPass()')
        self.assertOrdered(prepare, 'handle.synchronize()', 'handle.seekToEnd() == UInt64(byteCount)')
        self.assertOrdered(body(file, 'deinit'), 'handle.close()', 'removeItem(at: url)')
        self.assertIn('FileProtectionType.complete', file)

    def test_preview_and_full_export_use_same_pointwise_spatial_final_sequence(self):
        engine = source('HNCSEngine.swift')
        preview = body(engine, 'static func exportLinearRGBA(')
        self.assertOrdered(preview, 'if settings.requiresSpatial(effects: effects)', 'presetWork(linearSRGB:',
                           'HNCSPresetWorkFile(width: width, height: height)',
                           'writeTopDownRows(work, originY: 0, rows: height)',
                           'applySpatial(to: file, settings: settings',
                           'readTopDownRows(originY: 0, rows: height)',
                           'finishPresetWork(adjusted,')
        export = body(source('ImagePipeline.swift'), 'private static func exportFullSource(')
        self.assertOrdered(export, 'recipe.hncs.requiresSpatial(effects: recipe.effects)', 'HNCSPresetWorkFile(width: width, height: height)',
                           'HNCSEngine.presetWork(', 'spatialWork.writeTopDownRows(',
                           'HNCSEngine.applySpatial(to: spatialWork, settings: recipe.hncs',
                           'spatialWork.readTopDownRows(', 'HNCSEngine.finishPresetWork(',
                           'CILanczosScaleTransform', 'writeHEIF10Representation')
        self.assertEqual(export.count('HNCSEngine.applySpatial('), 1)
        self.assertEqual(preview.count('applySpatial('), 1)
        self.assertNotIn('[Float](repeating: 0, count: width * height', export)
        self.assertIn('captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs', compact(export))

    def test_spatial_flags_and_cancellation_cross_bridge_without_dropping_recipe(self):
        engine = source('HNCSEngine.swift')
        gate = body(engine, 'func requiresSpatial(effects:')
        self.assertIn('presetKey != "standard"', gate)
        self.assertIn('(effects.applyGrain && flags & 4 != 0)', gate)
        self.assertIn('(effects.applySharpness && flags & (8 | 16) != 0)', gate)
        spatial = body(engine, 'static func applySpatial(')
        self.assertOrdered(spatial, 'file.prepareForSpatialPass()', 'if isCancelled()',
                           'Unmanaged.passUnretained(cancellation).toOpaque()',
                           'settings.presetKey.withCString', 'hncs_apply_spatial_preset_file(',
                           'effects.applyGrain ? 1 : 0, effects.applySharpness ? 1 : 0',
                           'withExtendedLifetime(cancellation)',
                           'if status == -3 || isCancelled() { throw CancellationError() }',
                           'guard status == 0')
        self.assertIn('takeUnretainedValue().isCancelled() ? 1 : 0', spatial)
        legacy = body(engine, 'static func process(')
        self.assertIn('guard !settings.requiresSpatial(effects: effects) else { throw Error.spatialRequiresFloat }', legacy)


if __name__ == '__main__':
    unittest.main(verbosity=2)
