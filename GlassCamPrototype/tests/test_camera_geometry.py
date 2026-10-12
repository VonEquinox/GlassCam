"""Portable specification/source tests, NOT an Apple SDK or rendered-preview test.

The geometry model mirrors CameraFraming.swift to exercise window/aspect invariants.
An Xcode/device suite must still verify the Swift implementation and optical framing.
"""
import math
from pathlib import Path
import random
import unittest

ROOT = Path(__file__).resolve().parents[1]


def frame(width, height, aspect, control_band=112):
    width, height = max(0, width), max(0, height)
    vertical_controls = width > height
    band = min(max(0, control_band), max(width, height) * .3)
    available_width = max(0, width - 2 * band) if vertical_controls else width
    available_height = height if vertical_controls else max(0, height - 2 * band)
    aspect = aspect if math.isfinite(aspect) and aspect > 0 else 1
    photo_width = min(available_width, available_height * aspect)
    photo_height = photo_width / aspect
    x, y = (width - photo_width) / 2, (height - photo_height) / 2
    panes = [(0, 0, width, y), (0, y + photo_height, width, height - y - photo_height),
             (0, y, x, photo_height), (x + photo_width, y, width - x - photo_width, photo_height)]
    return (x, y, photo_width, photo_height), [p for p in panes if p[2] > 0 and p[3] > 0]


def wider_frame(width, height, photo_aspect, center_fov, wider_fov, wider_aspect):
    photo, _ = frame(width, height, photo_aspect)
    if not (all(math.isfinite(v) for v in [center_fov, wider_fov, wider_aspect]) and
            0 < center_fov < wider_fov < 180 and wider_aspect > 0 and photo[2] > 0 and photo[3] > 0):
        return None, False
    ratio = math.tan(math.radians(wider_fov / 2)) / math.tan(math.radians(center_fov / 2))
    if photo_aspect < 1:
        wide_height = photo[3] * ratio
        wide_width = wide_height * wider_aspect
    else:
        wide_width = photo[2] * ratio
        wide_height = wide_width / wider_aspect
    result = ((width - wide_width) / 2, (height - wide_height) / 2, wide_width, wide_height)
    return result, wide_width >= width and wide_height >= height


def overlap(a, b):
    return max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])) * max(
        0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))


class CameraGeometryTests(unittest.TestCase):
    def test_arbitrary_window_aspects_partition_without_center_overlap(self):
        rng = random.Random(5619)
        windows = [(390, 844), (844, 390), (430, 932), (932, 430), (1024, 1366),
                   (1366, 1024), (720, 720), (320, 480), (1600, 300), (300, 1600)]
        windows += [(rng.uniform(100, 3000), rng.uniform(100, 3000)) for _ in range(1000)]
        for width, height in windows:
            for aspect in [.75, 4/3, 1, 1.5, 2/3, 16/9]:
                photo, panes = frame(width, height, aspect)
                self.assertAlmostEqual(photo[2] / photo[3], aspect)
                self.assertAlmostEqual(photo[0] + photo[2]/2, width/2)
                self.assertAlmostEqual(photo[1] + photo[3]/2, height/2)
                self.assertAlmostEqual(photo[2]*photo[3] + sum(p[2]*p[3] for p in panes), width*height)
                for i, pane in enumerate(panes):
                    self.assertLess(overlap(photo, pane), 1e-6)
                    for other in panes[i + 1:]:
                        self.assertLess(overlap(pane, other), 1e-6)

    def test_invalid_and_zero_input_never_produces_nan(self):
        for size in [(0, 0), (0, 844), (844, 0), (-10, 500)]:
            for aspect in [0, -1, math.nan, math.inf]:
                photo, panes = frame(*size, aspect)
                self.assertTrue(all(math.isfinite(x) for rect in [photo] + panes for x in rect))

    def test_swift_source_uses_runtime_geometry_and_aspect_fit(self):
        framing = (ROOT / 'ios/GlassCam/CameraFraming.swift').read_text()
        view = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
        self.assertIn('GeometryReader', view)
        self.assertIn('camera.geometry?.photoAspectRatio', view)
        self.assertIn('CameraPreview(layer: layer, gravity: .resizeAspect)', view)
        self.assertIn('min(available.width, available.height * aspect)', framing)
        self.assertNotIn('18 / 9', framing)
        self.assertNotIn('UIScreen.main.bounds', view)
        self.assertIn('updateOrientation', view)

    def test_real_glass_and_capture_not_a_screenshot(self):
        view = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
        self.assertIn('content.glassEffect(.regular, in: Rectangle())', view)
        self.assertIn('content.buttonStyle(.glass)', view)
        self.assertIn('camera.captureProRAW', view)
        self.assertIn('case .success(let data): onCapture(data, export)', view)
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
        self.assertIn('peripheralPreviewLongEdge: settings.peripheralPreviewLongEdge', view)
        self.assertNotIn('outputMegapixels:', view[view.index('private func restartCamera'):])
        self.assertIn('let export = ExportSettings', view)
        self.assertIn('choices.first(where: { $0.megapixels == saved })', view)
        self.assertIn('$0 < settings.centerPreviewLongEdge', view)
        self.assertIn('camera.isCapturing || camera.isConfiguring', view)
        self.assertIn('Button("Retry camera") { restartCamera() }', view)
        self.assertIn('!camera.isReady && !camera.isConfiguring', view)
        self.assertIn('4096', settings)

    def test_wider_fov_matches_pinhole_scale_in_both_orientations(self):
        ratio = math.tan(math.radians(60)) / math.tan(math.radians(35))
        for width, height, aspect in [(390, 844, .75), (844, 390, 4/3)]:
            photo, _ = frame(width, height, aspect)
            wide, covered = wider_frame(width, height, aspect, 70, 120, aspect)
            self.assertTrue(covered)
            self.assertAlmostEqual(wide[2]/photo[2], ratio)
            self.assertAlmostEqual(wide[3]/photo[3], ratio)
            self.assertAlmostEqual(wide[2]/wide[3], aspect)
            self.assertAlmostEqual(wide[0] + wide[2]/2, width/2)
            self.assertAlmostEqual(wide[1] + wide[3]/2, height/2)

    def test_wider_video_aspect_preserved_and_missing_coverage_rejected(self):
        wide, _ = wider_frame(844, 390, 4/3, 70, 120, 1.5)
        self.assertAlmostEqual(wide[2]/wide[3], 1.5)
        for width, height, aspect in [(1600, 300, 4/3), (300, 1600, .75)]:
            _, covered = wider_frame(width, height, aspect, 70, 120, aspect)
            self.assertFalse(covered)
        for center, wider in [(70, 70), (70, 60), (0, 120), (70, 180), (70, math.nan)]:
            self.assertEqual(wider_frame(390, 844, .75, center, wider, .75), (None, False))

    def test_live_periphery_never_uses_arbitrary_fill_scaling(self):
        view = (ROOT / 'ios/GlassCam/CameraView.swift').read_text()
        geometry = (ROOT / 'ios/GlassCam/CameraFraming.swift').read_text()
        self.assertNotIn('.resizeAspectFill', view)
        self.assertIn('AVSampleBufferDisplayLayer', view)
        self.assertNotIn('AVCaptureVideoPreviewLayer', view)
        self.assertIn('.frame(width: extent.width, height: extent.height)', view)
        self.assertIn('framing.hasPeripheralCoverage', view)
        self.assertIn('selectedLens == .ultraWide || framing.hasPeripheralCoverage', view)
        self.assertIn('APPROX. ALIGNMENT / PARALLAX', view)
        self.assertNotIn('exact photograph framing', view)
        self.assertIn('tan(Double(widerFOV)', geometry)
        self.assertIn('if aspect < 1', geometry)


if __name__ == '__main__':
    unittest.main()
