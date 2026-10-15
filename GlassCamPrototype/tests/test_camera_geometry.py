"""Portable specification/source tests, NOT an Apple SDK or rendered-preview test.

The geometry model mirrors CameraFraming.swift to exercise window/aspect invariants.
An Xcode/device suite must still verify the Swift implementation and optical framing.
"""
import math
from pathlib import Path
import random
import unittest

ROOT = Path(__file__).resolve().parents[1]


def finite_nonnegative(value):
    return max(0, value) if math.isfinite(value) else 0


def valid_aspect(value):
    return value if math.isfinite(value) and value > 0 else 1


def frame(width, height, aspect):
    """Maximal full-window aspect fit; controls never reserve photograph space."""
    width, height = finite_nonnegative(width), finite_nonnegative(height)
    aspect = valid_aspect(aspect)
    photo_width = min(width, height * aspect)
    photo_height = photo_width / aspect
    x, y = (width - photo_width) / 2, (height - photo_height) / 2
    panes = [(0, 0, width, y), (0, y + photo_height, width, height - y - photo_height),
             (0, y, x, photo_height), (x + photo_width, y, width - x - photo_width, photo_height)]
    return (x, y, photo_width, photo_height), [p for p in panes if p[2] > 0 and p[3] > 0]


def chrome_layout(width, height, aspect, safe_area=(0, 0, 0, 0), accessible=False):
    """Independent chrome spec: safe area is (top, leading, bottom, trailing).

    Only spare-pane intersections are eligible. The fitted photo is deliberately
    computed before this function and is never returned as a resized alternative.
    """
    photo, _ = frame(width, height, aspect)
    width, height = finite_nonnegative(width), finite_nonnegative(height)
    top, leading, bottom, trailing = safe_area
    safe = (leading, top, max(0, width - leading - trailing), max(0, height - top - bottom))

    def usable(rect):
        x, y = max(rect[0], safe[0]), max(rect[1], safe[1])
        w = min(rect[0] + rect[2], safe[0] + safe[2]) - x
        h = min(rect[1] + rect[3], safe[1] + safe[3]) - y
        return (x + 8, y + 4, w - 16, h - 8) if w > 16 and h > 16 else (0, 0, 0, 0)

    if photo[0] > photo[1]:
        first = usable((0, 0, photo[0], height))
        second = usable((photo[0] + photo[2], 0, width - photo[0] - photo[2], height))
        if not accessible and min(first[2], second[2]) >= 100 and min(first[3], second[3]) >= 292:
            style = 'landscape'
        elif not accessible and first[2] >= 44 and second[2] >= 56 and min(first[3], second[3]) >= 212:
            style = 'compactVertical'
        else:
            style = 'separate'
    else:
        first = usable((0, 0, width, photo[1]))
        second = usable((0, photo[1] + photo[3], width, height - photo[1] - photo[3]))
        if not accessible and first[3] >= 94 and second[3] >= 112 and min(first[2], second[2]) >= 276:
            style = 'portrait'
        elif not accessible and first[3] >= 44 and second[3] >= 56 and min(first[2], second[2]) >= 312:
            style = 'compactHorizontal'
        else:
            style = 'separate'
    return style, first, second


def overlap(a, b):
    return max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])) * max(
        0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))


class CameraGeometryTests(unittest.TestCase):
    def assert_partition(self, width, height, aspect):
        photo, panes = frame(width, height, aspect)
        self.assertAlmostEqual(photo[2] / photo[3], aspect)
        self.assertAlmostEqual(photo[0] + photo[2] / 2, width / 2)
        self.assertAlmostEqual(photo[1] + photo[3] / 2, height / 2)
        self.assertAlmostEqual(photo[2] * photo[3] + sum(p[2] * p[3] for p in panes),
                               width * height, delta=max(1e-9, width * height * 1e-12))
        # At least one full dimension is saturated. Any uniform enlargement
        # would exceed the window, including on compact or extreme windows.
        self.assertTrue(math.isclose(photo[2], width, rel_tol=1e-12) or
                        math.isclose(photo[3], height, rel_tol=1e-12))
        self.assertTrue(photo[2] * 1.000001 > width or photo[3] * 1.000001 > height)
        tolerance = max(1e-9, width * height * 1e-12)
        for i, rect in enumerate([photo] + panes):
            self.assertGreaterEqual(rect[0], -1e-9)
            self.assertGreaterEqual(rect[1], -1e-9)
            self.assertGreaterEqual(rect[2], 0)
            self.assertGreaterEqual(rect[3], 0)
            self.assertLessEqual(rect[0] + rect[2], width + max(1e-9, width * 1e-12))
            self.assertLessEqual(rect[1] + rect[3], height + max(1e-9, height * 1e-12))
            for other in ([photo] + panes)[i + 1:]:
                self.assertLessEqual(overlap(rect, other), tolerance)

    def test_known_portrait_landscape_square_and_matching_windows(self):
        cases = [
            ((390, 844, .75), (0, 162, 390, 520)),
            ((844, 390, 4 / 3), (162, 0, 520, 390)),
            ((720, 720, .75), (90, 0, 540, 720)),
            ((720, 720, 4 / 3), (0, 90, 720, 540)),
            ((390, 520, .75), (0, 0, 390, 520)),
            ((520, 390, 4 / 3), (0, 0, 520, 390)),
            ((720, 720, 1), (0, 0, 720, 720)),
        ]
        for arguments, expected in cases:
            with self.subTest(window=arguments):
                photo, panes = frame(*arguments)
                self.assertEqual(photo, expected)
                self.assert_partition(*arguments)
                if expected[:2] == (0, 0):
                    self.assertEqual(panes, [])

    def test_perimeter_edges_are_exactly_window_minus_photo(self):
        photo, panes = frame(390, 844, .75)
        self.assertEqual(panes, [(0, 0, 390, 162), (0, 682, 390, 162)])
        photo, panes = frame(844, 390, 4 / 3)
        self.assertEqual(panes, [(0, 0, 162, 390), (682, 0, 162, 390)])
        for width, height, aspect in [(390, 844, .75), (844, 390, 4 / 3),
                                      (720, 720, 1), (1600, 300, 4 / 3),
                                      (300, 1600, .75)]:
            photo, panes = frame(width, height, aspect)
            # Pixel-center samples must belong to exactly one region, without
            # relying on a screenshot or accepting an invisible center overlap.
            for ix in range(41):
                for iy in range(41):
                    x, y = (ix + .5) * width / 41, (iy + .5) * height / 41
                    count = sum(rect[0] <= x < rect[0] + rect[2] and
                                rect[1] <= y < rect[1] + rect[3] for rect in [photo] + panes)
                    self.assertEqual(count, 1)

    def test_extreme_aspects_and_tiny_sizes_remain_maximal(self):
        for width, height in [(1600, 30), (30, 1600), (1e-6, 1000),
                              (1000, 1e-6), (1e6, 1e6), (1e-6, 1e-6)]:
            for aspect in [.001, .75, 1, 4 / 3, 1000]:
                with self.subTest(width=width, height=height, aspect=aspect):
                    self.assert_partition(width, height, aspect)

    def test_uniform_resize_preserves_normalized_photo_and_perimeter(self):
        for width, height, aspect in [(390, 844, .75), (844, 390, 4 / 3),
                                      (720, 720, .75), (300, 1600, .75)]:
            photo, panes = frame(width, height, aspect)
            for scale in [.25, .5, 2, 4]:
                larger_photo, larger_panes = frame(width * scale, height * scale, aspect)
                self.assertEqual(len(panes), len(larger_panes))
                for a, b in zip([photo] + panes, [larger_photo] + larger_panes):
                    for coordinate, scaled in zip(a, b):
                        self.assertAlmostEqual(coordinate * scale, scaled)

    def test_arbitrary_window_aspects_partition_without_center_overlap(self):
        rng = random.Random(5619)
        windows = [(390, 844), (844, 390), (430, 932), (932, 430), (1024, 1366),
                   (1366, 1024), (720, 720), (320, 480), (1600, 300), (300, 1600)]
        windows += [(rng.uniform(100, 3000), rng.uniform(100, 3000)) for _ in range(1000)]
        for width, height in windows:
            for aspect in [.75, 4/3, 1, 1.5, 2/3, 16/9]:
                with self.subTest(width=width, height=height, aspect=aspect):
                    self.assert_partition(width, height, aspect)

    def test_controls_use_available_panes_or_separate_panel(self):
        cases = [
            ((390, 844, .75), (59, 0, 34, 0), 'portrait'),
            ((932, 430, 4 / 3), (0, 59, 21, 59), 'landscape'),
            ((375, 788, .75), (44, 0, 34, 0), 'compactHorizontal'),
            ((844, 390, 4 / 3), (0, 59, 21, 59), 'compactVertical'),
            ((720, 720, .75), (0, 0, 0, 0), 'compactVertical'),
            ((390, 520, .75), (59, 0, 34, 0), 'separate'),
            ((520, 390, 4 / 3), (0, 59, 21, 59), 'separate'),
            ((720, 720, 1), (0, 0, 0, 0), 'separate'),
            ((1600, 30, 4 / 3), (0, 0, 0, 0), 'separate'),
            ((30, 1600, .75), (0, 0, 0, 0), 'separate'),
            ((0, 0, .75), (0, 0, 0, 0), 'separate'),
        ]
        for arguments, safe_area, expected in cases:
            with self.subTest(window=arguments, safe_area=safe_area):
                self.assertEqual(chrome_layout(*arguments, safe_area)[0], expected)
                self.assertEqual(chrome_layout(*arguments, safe_area, accessible=True)[0], 'separate')

    def test_safe_area_changes_only_control_placement_never_photo(self):
        rng = random.Random(8267)
        for _ in range(500):
            width, height = rng.uniform(100, 1600), rng.uniform(100, 1600)
            aspect = rng.choice([.75, 1, 4 / 3])
            before, panes = frame(width, height, aspect)
            for safe_area in [(0, 0, 0, 0), (59, 0, 34, 0), (0, 59, 21, 59),
                              (60, 100, 34, 100)]:
                style, first, second = chrome_layout(width, height, aspect, safe_area)
                self.assertEqual(frame(width, height, aspect)[0], before)
                for rect in [first, second]:
                    if rect[2] == 0 or rect[3] == 0:
                        continue
                    self.assertLessEqual(overlap(before, rect), 1e-8)
                    self.assertAlmostEqual(sum(overlap(pane, rect) for pane in panes),
                                           rect[2] * rect[3], delta=max(1e-8, width * height * 1e-12))
                    self.assertGreaterEqual(rect[0], safe_area[1] + 8 - 1e-9)
                    self.assertGreaterEqual(rect[1], safe_area[0] + 4 - 1e-9)
                    self.assertLessEqual(rect[0] + rect[2], width - safe_area[3] - 8 + 1e-9)
                    self.assertLessEqual(rect[1] + rect[3], height - safe_area[2] - 4 + 1e-9)

    def test_invalid_and_zero_input_never_produces_nan(self):
        for size in [(0, 0), (0, 844), (844, 0), (-10, 500), (500, -10),
                     (math.nan, 844), (844, math.nan), (math.inf, 844),
                     (844, -math.inf), (math.inf, math.nan)]:
            for aspect in [0, -1, math.nan, math.inf, .75, 4 / 3]:
                with self.subTest(size=size, aspect=aspect):
                    photo, panes = frame(*size, aspect)
                    self.assertTrue(all(math.isfinite(x) for rect in [photo] + panes for x in rect))
                    self.assertEqual(photo[2] * photo[3], 0)
                    self.assertEqual(panes, [])

    def test_invalid_aspect_falls_back_to_maximal_square(self):
        for aspect in [0, -1, math.nan, math.inf, -math.inf]:
            self.assertEqual(frame(390, 844, aspect), frame(390, 844, 1))
            self.assertEqual(frame(844, 390, aspect), frame(844, 390, 1))

    def test_swift_source_uses_runtime_geometry_and_aspect_fit(self):
        framing = (ROOT / 'ios/GlassCam/CameraFraming.swift').read_text()
        view = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
        self.assertIn('GeometryReader', view)
        self.assertIn('camera.geometry?.photoAspectRatio', view)
        self.assertIn('CameraPreview(layer: layer, gravity: .resizeAspect)', view)
        self.assertIn('min(width, height * outputAspect)', framing)
        self.assertNotIn('18 / 9', framing)
        self.assertNotIn('UIScreen.main.bounds', view)
        self.assertIn('updateOrientation', view)

    def test_black_bands_and_capture_not_a_screenshot(self):
        view = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
        self.assertIn('Color.black', view)
        self.assertNotIn('glassEffect', view)
        self.assertIn('.buttonStyle(.plain)', view)
        self.assertNotIn('.ultraThinMaterial', view)
        self.assertIn('camera.captureProRAW', view)
        self.assertIn('case .success(let data): onCapture(data, export, capturedRecipe)', view)
        self.assertIn('SYSTEM PREVIEW', view)
        self.assertIn('after capture', view)
        self.assertNotIn('UIGraphicsImageRenderer', view)
        self.assertNotIn('drawHierarchy', view)
        self.assertNotIn('scaleEffect(x: -1', view)

    def test_output_is_physical_lens_scoped_and_separate_from_preview(self):
        view = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
        settings = (ROOT / 'ios/GlassCam/CameraSettingsStore.swift').read_text()
        self.assertIn('camera.supportedOutputOptions', view)
        self.assertIn('camera.physicalCameraID', view)
        self.assertIn('UserDefaults', settings)
        self.assertIn('physicalCameraID: String, mode: String', settings)
        self.assertIn('camera.output.megapixels.byPhysicalLens.v1', settings)
        self.assertIn('centerPreviewLongEdge: settings.centerPreviewLongEdge', view)
        self.assertNotIn('outputMegapixels:', view[view.index('private func restartCamera'):])
        self.assertIn('let export = ExportSettings', view)
        self.assertIn('choices.first(where: { $0.megapixels == saved })', view)
        self.assertIn('camera.isCapturing || camera.isConfiguring', view)
        self.assertIn('Button("Retry camera") { restartCamera() }', view)
        self.assertIn('!camera.isReady && !camera.isConfiguring', view)
        self.assertIn('4096', settings)





if __name__ == '__main__':
    unittest.main()
