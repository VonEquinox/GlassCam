"""Portable three-switch recipe, migration and geometry specifications.

These models execute the persistence/ownership/geometry contracts independently
of Swift. They do not execute JSONDecoder, AVFoundation or Core Image. Companion
source tests bind the same contracts to Swift; native numerical stage bypass is
covered separately by the C++ tests.
"""
import copy
from dataclasses import asdict, dataclass
import itertools
import json
import unittest

from test_hncs_revision8_geometry import camera_frames, crop_pixels, crop_rect, select_output
from test_hncs_revision8_capture_recipe import EditorRecipeModel, square_recipe
import reference_runtime as reference


@dataclass(frozen=True)
class Effects:
    applyGrain: bool = True
    applySharpness: bool = True
    applyExtraCrop: bool = True


COMBINATIONS = tuple(Effects(*values) for values in itertools.product((False, True), repeat=3))
PRESETS = ('standard', 'nature', 'square-crop', 'film-grain-artistic', 'sharpness-high')


def decode_bool(mapping, key, default=True):
    value = mapping.get(key)
    if value is None:
        return default
    if type(value) is not bool:
        raise ValueError('invalid boolean: ' + key)
    return value


def decode_recipe(payload):
    """New flags win; active HNCS migrates old flags, while old FFCS stays on."""
    recipe = json.loads(payload)
    effect_payload = recipe.get('effects')
    if effect_payload is None:
        old = recipe['hncs']
        effects = (Effects(decode_bool(old, 'applyGrain'), decode_bool(old, 'applySharpness'), True)
                   if recipe['mode'] == 'hncs' else Effects())
    else:
        effects = Effects(**{key: decode_bool(effect_payload, key) for key in asdict(Effects())})
    recipe['hncs'].pop('applyGrain', None)
    recipe['hncs'].pop('applySharpness', None)
    recipe['effects'] = asdict(effects)
    return recipe


def make_recipe(mode, preset, effects):
    recipe = square_recipe()
    recipe['mode'] = mode
    recipe['hncs']['presetKey'] = preset
    recipe['hncs'].pop('applyGrain', None)
    recipe['hncs'].pop('applySharpness', None)
    recipe['effects'] = asdict(effects)
    return recipe


def hncs_stages(preset, effects):
    """Use original preset parameters, including the Standard outer bypass."""
    settings = reference.presets.settings(preset)
    return {
        'grain': preset != 'standard' and effects.applyGrain and bool(
            settings['film_grain'].get('ApplyFilmGrain') and settings['film_grain'].get('FilmGrainAmount')),
        'sharpness': preset != 'standard' and effects.applySharpness and bool(settings['sharpness'].get('amount')),
        'crop': effects.applyExtraCrop and settings['crop_aspect_ratio'] == 1,
    }


def recipe_square(recipe):
    return (recipe['mode'] == 'hncs' and recipe['hncs']['presetKey'] == 'square-crop'
            and recipe['effects']['applyExtraCrop'])


class EffectToggleCombinationModels(unittest.TestCase):
    def test_exactly_eight_independent_combinations_for_every_required_preset_and_ffcs(self):
        self.assertEqual(len(COMBINATIONS), 8)
        self.assertEqual(len(set(COMBINATIONS)), 8)
        expected_available = {
            'standard': (False, False, False),
            'nature': (False, True, False),
            'square-crop': (False, True, True),
            'film-grain-artistic': (True, False, False),
            'sharpness-high': (False, True, False),
        }
        for preset in PRESETS:
            for effects in COMBINATIONS:
                with self.subTest(preset=preset, effects=effects):
                    available = expected_available[preset]
                    expected = dict(zip(('grain', 'sharpness', 'crop'),
                                        (enabled and defined for enabled, defined
                                         in zip(asdict(effects).values(), available))))
                    self.assertEqual(hncs_stages(preset, effects), expected)
                    self.assertEqual(recipe_square(make_recipe('hncs', preset, effects)), expected['crop'])
        # FFCS has neither a preset crop nor a request to add one. Its grain and
        # sharpening enable bits are independent of this no-op third flag.
        for simulation in range(19):
            for effects in COMBINATIONS:
                recipe = make_recipe('ffcs', 'square-crop', effects)
                recipe['simulationIndex'] = simulation
                self.assertFalse(recipe_square(recipe))
                self.assertEqual(recipe['effects'], asdict(effects))

    def test_switches_do_not_mutate_original_preset_parameters(self):
        for preset in PRESETS:
            original = copy.deepcopy(reference.presets.settings(preset))
            for effects in COMBINATIONS:
                hncs_stages(preset, effects)
                self.assertEqual(reference.presets.settings(preset), original)
            self.assertEqual(original['source_payload'], reference.presets.preset_payload(preset))

    def test_enabling_absent_effect_never_invents_grain_sharpness_or_crop(self):
        for preset in PRESETS:
            all_on = hncs_stages(preset, Effects())
            for effects in COMBINATIONS:
                stage = hncs_stages(preset, effects)
                for name in ('grain', 'sharpness', 'crop'):
                    self.assertFalse(stage[name] and not all_on[name], (preset, effects, name))
        self.assertFalse(hncs_stages('sharpness-high', Effects())['grain'])
        self.assertFalse(hncs_stages('film-grain-artistic', Effects())['sharpness'])
        self.assertFalse(hncs_stages('nature', Effects())['crop'])

    def test_changing_one_switch_preserves_other_flags_and_all_color_settings(self):
        for mode, preset, effects in itertools.product(('hncs', 'ffcs'), PRESETS, COMBINATIONS):
            original = make_recipe(mode, preset, effects)
            for key, value in asdict(effects).items():
                changed = copy.deepcopy(original)
                changed['effects'][key] = not value
                self.assertNotEqual(changed, original)
                self.assertEqual({k: v for k, v in changed.items() if k != 'effects'},
                                 {k: v for k, v in original.items() if k != 'effects'})
                self.assertEqual(sum(changed['effects'][k] != original['effects'][k]
                                     for k in original['effects']), 1)

    def test_selecting_preset_or_mode_never_resets_flag_choices(self):
        for effects in COMBINATIONS:
            recipe = make_recipe('hncs', 'standard', effects)
            for mode in ('hncs', 'ffcs', 'hncs'):
                recipe['mode'] = mode
                for preset in PRESETS:
                    recipe['hncs']['presetKey'] = preset
                    self.assertEqual(recipe['effects'], asdict(effects))


class EffectToggleMigrationModels(unittest.TestCase):
    def test_legacy_all_four_explicit_grain_and_sharpness_choices_survive(self):
        for mode in ('hncs', 'ffcs'):
            for grain, sharp in itertools.product((False, True), repeat=2):
                old = square_recipe()
                old['mode'] = mode
                old.pop('effects', None)
                old['hncs'].update(applyGrain=grain, applySharpness=sharp)
                migrated = decode_recipe(json.dumps(old))
                expected = Effects(grain, sharp, True) if mode == 'hncs' else Effects()
                self.assertEqual(migrated['effects'], asdict(expected))
                self.assertNotIn('applyGrain', migrated['hncs'])
                self.assertNotIn('applySharpness', migrated['hncs'])
                for key in ('mode', 'exposureEV', 'illuminantKelvin', 'simulationIndex', 'seed'):
                    self.assertEqual(migrated[key], old[key])
                for key in migrated['hncs']:
                    self.assertEqual(migrated['hncs'][key], old['hncs'][key])

    def test_missing_legacy_flags_default_individually_without_erasing_explicit_false(self):
        for absent, retained in [('applyGrain', 'applySharpness'), ('applySharpness', 'applyGrain')]:
            old = square_recipe()
            old.pop('effects', None)
            old['hncs'].pop(absent, None)
            old['hncs'][retained] = False
            decoded = decode_recipe(json.dumps(old))['effects']
            self.assertTrue(decoded[absent])
            self.assertFalse(decoded[retained])
            self.assertTrue(decoded['applyExtraCrop'])

    def test_new_eight_combinations_round_trip_and_override_stale_legacy_fields(self):
        for effects in COMBINATIONS:
            recipe = make_recipe('hncs', 'nature', effects)
            recipe['hncs'].update(applyGrain=not effects.applyGrain, applySharpness=not effects.applySharpness)
            decoded = decode_recipe(json.dumps(recipe))
            self.assertEqual(decoded['effects'], asdict(effects))
            self.assertEqual(decode_recipe(json.dumps(decoded)), decoded)

    def test_missing_new_fields_default_individually_and_null_effects_use_legacy(self):
        recipe = square_recipe()
        recipe['effects'] = {'applyGrain': False}
        self.assertEqual(decode_recipe(json.dumps(recipe))['effects'], asdict(Effects(False, True, True)))
        recipe['effects'] = None
        recipe['hncs'].update(applyGrain=False, applySharpness=False)
        self.assertEqual(decode_recipe(json.dumps(recipe))['effects'], asdict(Effects(False, False, True)))

    def test_malformed_boolean_does_not_silently_become_default_or_true(self):
        for key in asdict(Effects()):
            for value in (0, 1, 'false', 'true', [], {}):
                recipe = make_recipe('hncs', 'nature', Effects())
                recipe['effects'][key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    decode_recipe(json.dumps(recipe))


class EffectToggleGeometryModels(unittest.TestCase):
    def test_crop_off_restores_full_sensor_pixels_for_before_and_after(self):
        for width, height in [(7, 4), (4, 7), (8, 5), (5, 8), (1, 9), (9, 1)]:
            pixels = [[(x, y) for x in range(width)] for y in range(height)]
            for effects in COMBINATIONS:
                recipe = make_recipe('hncs', 'square-crop', effects)
                crop = crop_rect(width, height, recipe_square(recipe))
                before = crop_pixels(pixels, crop)
                after = copy.deepcopy(before)
                self.assertEqual(before, after)
                if not effects.applyExtraCrop:
                    self.assertEqual(before, pixels)
                    self.assertEqual((crop.x, crop.y, crop.width, crop.height), (0, 0, width, height))
                else:
                    self.assertEqual((len(before[0]), len(before)), (min(width, height),) * 2)

    def test_crop_off_restores_selected_sensor_output_in_both_orientations(self):
        for source in [(8064, 6048), (6048, 8064)]:
            for selected in [(4032, 3024), (3024, 4032), source, None]:
                for effects in COMBINATIONS:
                    square = recipe_square(make_recipe('hncs', 'square-crop', effects))
                    output = select_output(*source, selected, square=square)
                    original = select_output(*source, selected, square=False)
                    self.assertEqual(output, (min(original),) * 2 if square else original)
                    self.assertLessEqual(output[0] * output[1], source[0] * source[1])

    def test_crop_off_restores_uncropped_camera_frame_and_physical_source_scale(self):
        for width, height, aspect in [(390, 844, .75), (844, 390, 4 / 3), (720, 720, .75)]:
            for effects in COMBINATIONS:
                square = recipe_square(make_recipe('hncs', 'square-crop', effects))
                photo, source = camera_frames(width, height, aspect, square)
                self.assertAlmostEqual(source[2] / source[3], aspect)
                if not square:
                    self.assertEqual(photo, source)
                    self.assertAlmostEqual(photo[2] / photo[3], aspect)
                    self.assertEqual((photo[2], photo[3]),
                                     (min(width, height * aspect), min(width, height * aspect) / aspect))

    def test_ffcs_crop_flag_is_noop_even_with_saved_square_hncs_preset(self):
        for effects in COMBINATIONS:
            recipe = make_recipe('ffcs', 'square-crop', effects)
            self.assertEqual(select_output(8064, 6048, (4032, 3024), recipe_square(recipe)), (4032, 3024))


class EffectToggleFrozenRecipeModels(unittest.TestCase):
    def test_eight_flag_combinations_are_distinct_cache_and_metadata_identities(self):
        for mode, preset in itertools.product(('hncs', 'ffcs'), PRESETS):
            keys = {json.dumps(make_recipe(mode, preset, effects), sort_keys=True) for effects in COMBINATIONS}
            self.assertEqual(len(keys), 8)
            for key in keys:
                decoded = decode_recipe(key)
                self.assertEqual(set(decoded['effects']), set(asdict(Effects())))

    def test_shutter_import_export_snapshot_keeps_flags_after_late_editor_changes(self):
        for effects in COMBINATIONS:
            captured = make_recipe('hncs', 'square-crop', effects)
            editor = EditorRecipeModel(controls=copy.deepcopy(captured))
            operation = editor.begin_import(explicit_recipe=captured)
            editor.controls['effects'] = asdict(Effects(*(not v for v in asdict(effects).values())))
            editor.controls['hncs']['presetKey'] = 'standard'
            self.assertTrue(editor.finish(operation))
            self.assertEqual(editor.rendered, captured)
            self.assertFalse(editor.can_deliver)
            self.assertTrue(editor.source_retained)

    def test_import_freezes_each_flag_and_rerender_reestablishes_delivery(self):
        for effects in COMBINATIONS:
            editor = EditorRecipeModel(controls=make_recipe('ffcs', 'nature', effects))
            first = editor.begin_import()
            self.assertTrue(editor.finish(first))
            self.assertTrue(editor.can_deliver)
            editor.controls['effects']['applyExtraCrop'] = not effects.applyExtraCrop
            self.assertFalse(editor.can_deliver)
            second = editor.begin_import()
            self.assertTrue(editor.finish(second))
            self.assertTrue(editor.can_deliver)


if __name__ == '__main__':
    unittest.main(verbosity=2)
