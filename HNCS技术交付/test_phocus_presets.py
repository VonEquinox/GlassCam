import unittest

import numpy as np

import hncs_pipeline as h
from phocus_presets import (FACTORY_SETTING_FILES, PRESET_CHOICES, apply_preset,
                            catalog, preset_key, resolve_film_curve, settings)


class PhocusPresetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets = h.load_assets()

    def test_catalog_contains_all_extracted_factory_settings(self):
        names = catalog()["factory_setting_names"]
        self.assertEqual(names[:4], ["Standard", "Product", "Portrait", "Nature"])
        self.assertIn("Square Crop", names)
        self.assertIn("Tungsten", names)

    def test_every_extracted_settings_file_has_a_portable_key(self):
        source_files = set(catalog()["source_files"])
        mapped_files = set(FACTORY_SETTING_FILES.values())
        self.assertEqual(source_files, mapped_files)
        self.assertGreaterEqual(len(PRESET_CHOICES), len(source_files))
        for key in PRESET_CHOICES:
            self.assertEqual(settings(key)["name"], preset_key(key))

    def test_native_curve_families_and_as_shot_resolution(self):
        standard, p_standard = resolve_film_curve("standard", self.assets, working_space="legacy")
        as_shot, p_as_shot = resolve_film_curve("as-shot", self.assets, working_space="legacy", raw_film_curve=2)
        old, p_old = resolve_film_curve("old-standard", self.assets, working_space="legacy")
        linear, p_linear = resolve_film_curve("linear", self.assets, working_space="legacy")
        repro, p_repro = resolve_film_curve("standard", self.assets, intent="reproduction", working_space="legacy")
        self.assertEqual(p_as_shot["resolved_film_curve_type"], 2)
        self.assertEqual(p_standard["resolved_film_curve_type"], 2)
        self.assertEqual(p_old["resolved_film_curve_type"], 0)
        self.assertEqual(p_linear["resolved_film_curve_type"], 7)
        self.assertEqual(p_repro["resolved_film_curve_type"], 7)
        self.assertTrue(np.array_equal(standard, as_shot))
        self.assertFalse(np.array_equal(standard, old))
        self.assertFalse(np.array_equal(standard, linear))
        self.assertTrue(np.array_equal(linear, repro))

    def test_nature_tone_and_saturation_presets_change_codes(self):
        source = np.linspace(0, 65535, 17, dtype=np.uint16).reshape(1, 17, 1)
        source = np.repeat(source, 3, axis=2)
        nature, nature_meta = apply_preset(source, "nature")
        standard, _ = apply_preset(source, "standard")
        self.assertTrue(nature_meta["tone_curve_applied"])
        self.assertFalse(np.array_equal(nature, standard))
        self.assertLess(int(nature[0, 5, 0]), int(standard[0, 5, 0]))
        saturated_source = np.array([[[10000, 30000, 50000]]], dtype=np.uint16)
        saturated, saturated_meta = apply_preset(saturated_source, "saturated")
        self.assertEqual(saturated_meta["saturation_applied"], 10.0)
        self.assertGreater(int(saturated[0, 0, 2] - saturated[0, 0, 0]),
                           int(saturated_source[0, 0, 2] - saturated_source[0, 0, 0]))

    def test_portrait_product_presets_preserve_color_core_and_record_sharpness(self):
        source = np.array([[[10000, 20000, 30000]]], dtype=np.uint16)
        for name, amount in (("portrait", 90), ("product", 350)):
            output, meta = apply_preset(source, name)
            self.assertTrue(np.array_equal(output, source))
            self.assertEqual(meta["preset_settings"]["sharpness"]["amount"], amount)
            self.assertFalse(meta["sharpness_requested"])

    def test_native_white_balance_and_film_grain_presets_are_applied(self):
        daylight = settings("daylight")
        nature = settings("nature")
        self.assertEqual(daylight["native_wb_gains"], nature["native_wb_gains"])
        self.assertAlmostEqual(daylight["native_wb_gains"][1], 1.0)
        source = np.full((32, 32, 3), 30000, dtype=np.uint16)
        output, meta = apply_preset(source, "film-grain-fine-texture")
        self.assertTrue(meta["film_grain_requested"])
        self.assertTrue(meta["film_grain_applied"])
        self.assertFalse(np.array_equal(output, source))
        output2, meta2 = apply_preset(source, "film-grain-fine-texture")
        self.assertTrue(np.array_equal(output, output2))
        self.assertTrue(meta2["film_grain_applied"])
        rows = catalog()["binary_evidence"]["white_balance_presets"]["rows"]
        for name, row in rows.items():
            cfg = settings(name)
            self.assertTrue(np.allclose(cfg["native_wb_gains"], row["normalized_gains"], atol=0, rtol=0))
            self.assertTrue(np.allclose(cfg["native_tint_multiplier"], row["tint_multiplier"], atol=0, rtol=0))

    def test_all_extracted_presets_execute_the_portable_entrypoint(self):
        source = np.zeros((8, 8, 3), dtype=np.uint16)
        source[2:6, 2:6] = [10000, 30000, 50000]
        for rel in catalog()["source_files"]:
            key = next(k for k, filename in FACTORY_SETTING_FILES.items() if filename == rel)
            output, meta = apply_preset(source, key, apply_sharpness=True)
            self.assertEqual(output.shape, source.shape, key)
            self.assertEqual(meta["preset"], preset_key(key))

    def test_explicit_sharpness_switch_applies_portable_filter(self):
        source = np.zeros((9, 9, 3), dtype=np.uint16)
        source[4, 4] = 40000
        output, meta = apply_preset(source, "product", apply_sharpness=True)
        self.assertTrue(meta["sharpness_requested"])
        self.assertTrue(meta["sharpness_applied"])
        self.assertFalse(np.array_equal(output, source))


if __name__ == "__main__":
    unittest.main()
