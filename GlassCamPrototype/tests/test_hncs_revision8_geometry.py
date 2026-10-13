"""Portable SquareCrop specification, not Core Image/Apple SDK execution.

The independent integer-pixel model checks crop bounds, parity, output selection,
matching before/after geometry and camera presentation. Source-contract tests in
this suite tie these requirements to the Swift dataflow; hardware QA remains
necessary for bitmap orientation and optical framing.
"""
from dataclasses import dataclass
import math
from pathlib import Path
import random
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import reference_runtime as reference


@dataclass(frozen=True)
class PixelCrop:
    x: int
    y: int
    width: int
    height: int

    def ci_rect(self, source_height):
        return self.x, source_height - self.y - self.height, self.width, self.height


def crop_rect(width, height, square=False):
    if width <= 0 or height <= 0:
        raise ValueError('invalid source')
    if not square:
        return PixelCrop(0, 0, width, height)
    side = min(width, height)
    return PixelCrop((width - side) // 2, (height - side) // 2, side, side)


def select_output(source_width, source_height, target=None, square=False):
    """Validate physical-camera selection before adapting it to the final crop."""
    crop = crop_rect(source_width, source_height, square)
    if target is None:
        return crop.width, crop.height
    w, h = target
    if w is None or h is None or w <= 0 or h <= 0:
        raise ValueError('incomplete target')
    if (source_width < source_height) != (w < h):
        w, h = h, w
    if (w > source_width or h > source_height or
            abs(w / h - source_width / source_height) >= 1e-12):
        raise ValueError('unsupported physical target')
    return (min(w, h), min(w, h)) if square else (w, h)


def crop_pixels(rows, crop):
    return [row[crop.x:crop.x + crop.width]
            for row in rows[crop.y:crop.y + crop.height]]


def camera_frames(width, height, source_aspect, square):
    """Fit the final photograph, preserving the uncropped camera's scale."""
    aspect = 1 if square else source_aspect
    photo_w = min(width, height * aspect)
    photo_h = photo_w / aspect
    photo = ((width - photo_w) / 2, (height - photo_h) / 2, photo_w, photo_h)
    if square:
        source_w = photo_w * max(1, source_aspect)
        source_h = photo_h / min(1, source_aspect)
    else:
        source_w, source_h = photo_w, photo_h
    source = ((width - source_w) / 2, (height - source_h) / 2, source_w, source_h)
    return photo, source


class SquareCropGeometryModelTests(unittest.TestCase):
    def test_odd_even_and_one_pixel_exact_rectangles(self):
        cases = [
            ((7, 4), PixelCrop(1, 0, 4, 4)),
            ((4, 7), PixelCrop(0, 1, 4, 4)),
            ((8, 5), PixelCrop(1, 0, 5, 5)),
            ((5, 8), PixelCrop(0, 1, 5, 5)),
            ((1, 1), PixelCrop(0, 0, 1, 1)),
            ((1, 2), PixelCrop(0, 0, 1, 1)),
            ((2, 1), PixelCrop(0, 0, 1, 1)),
            ((1, 4097), PixelCrop(0, 2048, 1, 1)),
            ((4097, 1), PixelCrop(2048, 0, 1, 1)),
        ]
        for (width, height), expected in cases:
            with self.subTest(width=width, height=height):
                self.assertEqual(crop_rect(width, height, True), expected)
                self.assertEqual(crop_rect(width, height), PixelCrop(0, 0, width, height))

    def test_exhaustive_small_rectangles_are_contained_centered_and_integer_aligned(self):
        for width in range(1, 65):
            for height in range(1, 65):
                crop = crop_rect(width, height, True)
                self.assertEqual(crop.width, crop.height)
                self.assertEqual(crop.width, min(width, height))
                self.assertGreaterEqual(crop.x, 0)
                self.assertGreaterEqual(crop.y, 0)
                self.assertLessEqual(crop.x + crop.width, width)
                self.assertLessEqual(crop.y + crop.height, height)
                # Extra pixel from an odd difference has an explicit, stable bias.
                self.assertIn(width - crop.width - 2 * crop.x, (0, 1))
                self.assertIn(height - crop.height - 2 * crop.y, (0, 1))
                self.assertTrue(all(type(x) is int for x in vars(crop).values()))

    def test_integer_crop_model_matches_revision8_reference_for_all_small_dimensions(self):
        settings = reference.presets.settings('square-crop')
        for width in range(1, 33):
            for height in range(1, 33):
                crop = crop_rect(width, height, True)
                actual = reference.presets.resolve_crop((height, width, 3), settings)
                self.assertEqual(actual['pixel_bounds'],
                                 [crop.x, crop.y, crop.x + crop.width, crop.y + crop.height])
                self.assertEqual(actual['aspect_ratio'], 1)
        self.assertIsNone(reference.presets.resolve_crop((7, 4, 3),
                                                       reference.presets.settings('standard')))

    def test_ci_coordinate_round_trip_preserves_odd_dimension_crop(self):
        for width, height in [(4, 7), (7, 4), (1, 2), (1, 3), (2, 1), (4031, 3024), (3024, 4031)]:
            crop = crop_rect(width, height, True)
            x, ci_y, w, h = crop.ci_rect(height)
            self.assertEqual((x, height - ci_y - h, w, h),
                             (crop.x, crop.y, crop.width, crop.height))
            self.assertGreaterEqual(ci_y, 0)
            self.assertLessEqual(ci_y + h, height)
        # This deliberately distinguishes odd portrait from accidental double-flip.
        self.assertEqual(crop_rect(4, 7, True).ci_rect(7), (0, 2, 4, 4))

    def test_before_after_wipe_uses_identical_source_pixels_and_shape(self):
        for width, height in [(7, 4), (4, 7), (1, 9), (9, 1), (1, 1), (8, 5), (5, 8)]:
            pixels = [[(x, y, y * width + x) for x in range(width)] for y in range(height)]
            rect = crop_rect(width, height, True)
            before = crop_pixels(pixels, rect)
            after = [[(x, y, index + 1000) for x, y, index in row] for row in before]
            self.assertEqual((len(before[0]), len(before)), (rect.width, rect.height))
            self.assertEqual((len(after[0]), len(after)), (rect.width, rect.height))
            for row in range(rect.height):
                for column in range(rect.width):
                    self.assertEqual(before[row][column][:2], after[row][column][:2])
                    self.assertEqual(before[row][column][:2], (column + rect.x, row + rect.y))

    def test_native_export_is_true_source_square_without_upscale(self):
        for source in [(8064, 6048), (6048, 8064), (4031, 3024), (3024, 4031), (1, 1), (1, 17)]:
            output = select_output(*source, square=True)
            self.assertEqual(output, (min(source), min(source)))
            self.assertLessEqual(output[0], source[0])
            self.assertLessEqual(output[1], source[1])
            self.assertEqual(select_output(*source), source)

    def test_physical_output_rotation_is_resolved_before_square_target_selection(self):
        for source in [(8064, 6048), (6048, 8064)]:
            for target in [(4032, 3024), (3024, 4032)]:
                with self.subTest(source=source, target=target):
                    self.assertEqual(select_output(*source, target, square=True), (3024, 3024))
                    expected = (4032, 3024) if source[0] > source[1] else (3024, 4032)
                    self.assertEqual(select_output(*source, target), expected)
                    self.assertAlmostEqual(expected[0] / source[0], expected[1] / source[1])

    def test_square_crop_cannot_hide_invalid_upscale_or_aspect_selection(self):
        invalid = [(9000, 6750), (4001, 3000), (3024, 3024), (10000, 1),
                   (4032, None), (None, 3024), (0, 0), (-1, 3)]
        for target in invalid:
            for square in [False, True]:
                with self.subTest(target=target, square=square):
                    with self.assertRaises(ValueError):
                        select_output(4032, 3024, target, square)
        for source in [(0, 1), (1, 0), (-1, 1), (1, -1)]:
            with self.assertRaises(ValueError):
                select_output(*source, square=True)

    def test_crop_selection_preserves_uniform_downsample_and_square_encoder_aspect(self):
        rng = random.Random(8)
        for _ in range(1000):
            numerator, denominator = rng.randrange(1, 20), rng.randrange(1, 20)
            factor, reduction = rng.randrange(1, 200), rng.randrange(1, 6)
            source = (numerator * factor * reduction, denominator * factor * reduction)
            target = (numerator * factor, denominator * factor)
            crop = crop_rect(*source, True)
            output = select_output(*source, target, square=True)
            self.assertEqual(output[0], output[1])
            self.assertAlmostEqual(output[0] / crop.width, output[1] / crop.height)
            self.assertAlmostEqual(output[0] / crop.width, 1 / reduction)
            self.assertLessEqual(output[0] * output[1], crop.width * crop.height)

    def test_final_square_camera_frame_is_maximal_with_unstretched_center_source(self):
        for width, height in [(390, 844), (844, 390), (720, 720), (1, 8), (8, 1)]:
            for aspect in [.75, 4 / 3, 1, 16 / 9]:
                photo, source = camera_frames(width, height, aspect, True)
                self.assertEqual(photo[2], min(width, height))
                self.assertEqual(photo[2], photo[3])
                self.assertAlmostEqual(source[2] / source[3], aspect)
                self.assertLessEqual(source[0], photo[0])
                self.assertLessEqual(source[1], photo[1])
                self.assertGreaterEqual(source[0] + source[2], photo[0] + photo[2])
                self.assertGreaterEqual(source[1] + source[3], photo[1] + photo[3])
                for rect in [photo, source]:
                    self.assertAlmostEqual(rect[0] + rect[2] / 2, width / 2)
                    self.assertAlmostEqual(rect[1] + rect[3] / 2, height / 2)

    def test_camera_crop_preserves_physical_fov_scale_in_both_orientations(self):
        ratio = math.tan(math.radians(60)) / math.tan(math.radians(35))
        for width, height, aspect in [(390, 844, .75), (844, 390, 4 / 3)]:
            photo, source = camera_frames(width, height, aspect, True)
            sensor_extent = source[3] if aspect < 1 else source[2]
            wider_extent = sensor_extent * ratio
            self.assertAlmostEqual(wider_extent / sensor_extent, ratio)
            # Using the square's edge as sensor extent would shrink the periphery.
            self.assertGreater(wider_extent, photo[2] * ratio)


if __name__ == '__main__':
    unittest.main(verbosity=2)
