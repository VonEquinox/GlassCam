"""Scoped Swift source contracts for independent grain/sharpen/crop switches.

These are dataflow/ownership and decoder-source checks, not a Swift build or
runtime JSONDecoder/UI/encoder test. Numerical FFCS stage gates are exercised by
the C++ suite; portable migration and geometry specifications live separately.
"""
from pathlib import Path
import re
import unittest

from test_hncs_revision8_source import body, compact, source, stored_members

ROOT = Path(__file__).resolve().parents[1]
FLAGS = ('applyGrain', 'applySharpness', 'applyExtraCrop')


def calls(text, marker):
    """Read each complete call, allowing nested parentheses and multiline args."""
    offset = 0
    while (start := text.find(marker + '(', offset)) >= 0:
        opened = start + len(marker)
        depth = 1
        for end in range(opened + 1, len(text)):
            depth += (text[end] == '(') - (text[end] == ')')
            if depth == 0:
                yield text[opened + 1:end]
                offset = end + 1
                break
        else:
            raise AssertionError('Unterminated call: ' + marker)


def coding_keys(declaration):
    keys = body(declaration, 'private enum CodingKeys:')
    return set(re.findall(r'\b\w+\b', re.sub(r'\bcase\b', '', keys)))


class EffectToggleSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline = source('ImagePipeline.swift')
        cls.hncs = source('HNCSEngine.swift')
        cls.ffcs = source('FFCSEngine.swift')
        cls.content = source('ContentView.swift')
        cls.camera = source('CameraView.swift')
        cls.live = source('LiveColorProxy.swift')

    def test_exactly_three_default_on_flags_have_one_serialized_authority(self):
        self.assertRegex(self.pipeline, r'struct EffectToggles:\s*Codable,\s*Equatable,\s*Sendable')
        fields = stored_members(self.pipeline, 'struct EffectToggles:')
        self.assertEqual(set(fields), set(FLAGS))
        self.assertTrue(all(value == ('var', '', 'true') for value in fields.values()))
        declaration = body(self.pipeline, 'struct EffectToggles:')
        self.assertEqual(coding_keys(declaration), set(FLAGS))
        self.assertNotIn('func ==', declaration)
        self.assertNotIn('func encode(', declaration)
        hncs_fields = stored_members(self.hncs, 'struct HNCSSettings:')
        self.assertTrue(set(FLAGS).isdisjoint(hncs_fields))
        self.assertEqual(stored_members(self.pipeline, 'struct ProcessingRecipe:')['effects'],
                         ('let', 'EffectToggles', ''))

    def test_partial_new_effects_decode_each_missing_flag_as_true_and_reject_bad_types(self):
        declaration = body(self.pipeline, 'struct EffectToggles:')
        decoder = compact(body(declaration, 'init(from decoder:'))
        for flag in FLAGS:
            self.assertIn(f'{flag} = try values.decodeIfPresent(Bool.self, forKey: .{flag}) ?? true', decoder)
        self.assertNotIn('try?', decoder)
        self.assertNotIn('Int.self', decoder)
        self.assertNotIn('String.self', decoder)

    def test_recipe_coding_keys_include_every_snapshot_field_and_new_effects_win(self):
        declaration = body(self.pipeline, 'struct ProcessingRecipe:')
        self.assertEqual(coding_keys(declaration), set(stored_members(self.pipeline, 'struct ProcessingRecipe:')))
        decoder = compact(body(declaration, 'init(from decoder:'))
        self.assertIn('if let savedEffects = try values.decodeIfPresent(EffectToggles.self, forKey: .effects) { effects = savedEffects }', decoder)
        self.assertNotIn('try?', decoder)
        self.assertNotIn('func encode(', declaration)
        self.assertNotIn('func ==', declaration)

    def test_legacy_hncs_flags_migrate_only_for_active_hncs_and_crop_defaults_true(self):
        declaration = body(self.pipeline, 'struct ProcessingRecipe:')
        decoder = compact(body(declaration, 'init(from decoder:'))
        self.assertIn('else if mode == .hncs, values.contains(.hncs), try !values.decodeNil(forKey: .hncs)', decoder)
        self.assertIn('values.nestedContainer(keyedBy: LegacyEffectKeys.self, forKey: .hncs)', decoder)
        for flag in ('applyGrain', 'applySharpness'):
            self.assertIn(f'{flag}: try legacy.decodeIfPresent(Bool.self, forKey: .{flag}) ?? true', decoder)
        self.assertIn('applyExtraCrop: true)', decoder)
        self.assertIn('else { effects = .standard }', decoder)
        self.assertLess(decoder.index('effects = savedEffects'), decoder.index('else if mode == .hncs'))
        # Use the previous key so the migration can actually discover old data.
        self.assertIn('editor.processingRecipe.revision8.v1', self.content)

    def test_editor_restore_persist_adopt_and_rerender_include_all_effects(self):
        self.assertIn('@Published var effects = EffectToggles.standard { didSet { persistRecipe() } }', self.content)
        self.assertIn('effects = saved.effects', body(self.content, 'init(defaults:'))
        self.assertIn('effects = snapshot.effects', body(self.content, 'private func adoptRecipeSnapshot('))
        self.assertIn('effects: effects', body(self.content, 'private var recipe:'))
        self.assertIn('JSONEncoder().encode(recipe)', body(self.content, 'private func persistRecipe()'))
        changed = body(self.content, '.onChange(of: model.effects)')
        self.assertIn('if !cameraPresented { Task { await model.render() } }', changed)
        self.assertIn('processed?.recipe != recipe', self.content)
        self.assertIn('processed != nil && !busy && !hasPendingChanges', self.content)

    def test_both_surfaces_bind_same_three_controls_and_none_depend_on_current_preset(self):
        controls = body(self.content, 'struct EffectToggleControls:')
        toggles = re.findall(r'Toggle\("([^"]+)", isOn: \$effects\.(\w+)\)', controls)
        self.assertEqual({flag for _, flag in toggles}, set(FLAGS))
        self.assertEqual(len(toggles), 3)
        self.assertNotIn('.disabled(', controls)
        self.assertIn('EffectToggleControls(effects: $model.effects, mode: model.colorMode, hncs: model.hncs)', self.content)
        self.assertIn('EffectToggleControls(effects: $effects, mode: colorMode, hncs: hncs)', self.camera)
        self.assertIn('effects: $model.effects', self.content)
        self.assertIn('@Binding var effects: EffectToggles', self.camera)
        for identifier in ('effects.sharpening', 'effects.grain', 'effects.extraCrop'):
            self.assertIn(f'.accessibilityIdentifier("{identifier}")', controls)

    def test_preset_and_simulation_selection_do_not_reset_global_flags(self):
        preset_controls = body(self.content, 'struct HNCSPresetControls:')
        self.assertIn('selection: $settings.presetKey', preset_controls)
        self.assertNotIn('effects', preset_controls)
        for field in ('model.colorMode', 'model.simulationIndex', 'model.hncs'):
            self.assertNotIn('effects', body(self.content, f'.onChange(of: {field})'))
        # A reset of a preset/color group must also preserve independent gates.
        reset = body(self.content, 'Button(model.colorMode == .hncs ? "Reset HNCS effect"')
        self.assertNotIn('effects', reset)
        self.assertNotRegex(self.camera, r'effects\s*=\s*\.standard')

    def test_hncs_crop_and_spatial_gates_only_enable_source_defined_stages(self):
        crop = compact(body(self.hncs, 'func crop(effects:'))
        self.assertEqual(crop, 'effects.applyExtraCrop && presetKey == "square-crop" ? .centeredSquare : .none')
        spatial = compact(body(self.hncs, 'func requiresSpatial(effects:'))
        self.assertIn('guard presetKey != "standard"', spatial)
        self.assertIn('(effects.applyGrain && flags & 4 != 0)', spatial)
        self.assertIn('(effects.applySharpness && flags & (8 | 16) != 0)', spatial)
        self.assertEqual(compact(body(self.pipeline, 'var crop: ImageCrop')),
                         'mode == .hncs ? hncs.crop(effects: effects) : .none')
        bridge = compact(body(self.hncs, 'static func applySpatial('))
        self.assertIn('settings.presetKey.withCString', bridge)
        self.assertIn('effects.applyGrain ? 1 : 0, effects.applySharpness ? 1 : 0', bridge)

    def test_every_pipeline_backend_call_receives_same_frozen_effects(self):
        names = ('HNCSEngine.exportLinearRGBA', 'HNCSEngine.presetWork', 'HNCSEngine.applySpatial',
                 'HNCSEngine.finishPresetWork', 'FFCSEngine.exportLinearRGBA', 'FFCSEngine.exportLinearRGBStrip')
        counts = {}
        for name in names:
            invocations = list(calls(self.pipeline, name))
            self.assertTrue(invocations, name)
            counts[name] = len(invocations)
            for invocation in invocations:
                self.assertIn('effects: recipe.effects', compact(invocation), name)
                self.assertNotIn('effects: .standard', invocation)
        self.assertEqual(counts['HNCSEngine.exportLinearRGBA'], 2)
        self.assertEqual(counts['FFCSEngine.exportLinearRGBA'], 1)
        self.assertEqual(counts['FFCSEngine.exportLinearRGBStrip'], 1)
        export = body(self.pipeline, 'private static func exportFullSource(')
        self.assertIn('let recipe = processed.recipe', export)
        self.assertIn('recipe.hncs.requiresSpatial(effects: recipe.effects)', export)

    def test_both_backend_caches_include_flags_and_preserve_inflight_owners(self):
        hncs_fields = stored_members(self.hncs, 'private struct ContextKey:')
        self.assertEqual(hncs_fields['effects'], ('let', 'EffectToggles', ''))
        hncs_cache = body(self.hncs, 'private final class ContextCache:')
        self.assertIn('effects: effects', hncs_cache)
        self.assertIn('cached.key == key', hncs_cache)
        ffcs_cache = compact(body(self.ffcs, 'private final class ContextCache:'))
        self.assertIn('cached.effects == effects', ffcs_cache)
        self.assertIn('ffcs_create_options(path, simulationIndex, effects.applyGrain ? 1 : 0, effects.applySharpness ? 1 : 0', ffcs_cache)
        self.assertIn('simulationIndex: simulationIndex, effects: effects)', ffcs_cache)
        self.assertEqual(stored_members(self.ffcs, 'private final class ContextOwner:')['effects'],
                         ('let', 'EffectToggles', ''))
        for marker in ('static func exportLinearRGBStrip(', 'private static func render('):
            method = compact(body(self.ffcs, marker))
            self.assertIn('contextCache.context(directory: directory, simulationIndex: simulationIndex, effects: effects)', method)
            self.assertIn('withExtendedLifetime(context)', method)

    def test_ffcs_preview_and_float_paths_forward_effects_without_adding_crop(self):
        for marker in ('static func process(', 'static func exportLinearRGBA('):
            render_call = list(calls(body(self.ffcs, marker), 'render'))
            self.assertEqual(len(render_call), 1)
            self.assertIn('effects: effects', compact(render_call[0]))
        self.assertNotIn('applyExtraCrop', self.ffcs)
        self.assertIn('[Float](repeating: 1, count: count * 4)', body(self.ffcs, 'static func exportLinearRGBA('))
        self.assertIn('ffcs_process_linear_rgb_strip(', body(self.ffcs, 'static func exportLinearRGBStrip('))
        self.assertIn('ffcs_process_linear_rgb_optimized(', body(self.ffcs, 'private static func render('))

    def test_shutter_retention_render_and_save_use_complete_immutable_snapshot(self):
        shutter = body(self.camera, 'private func shutter(')
        snapshots = list(calls(shutter, 'ProcessingRecipe'))
        self.assertEqual(len(snapshots), 1)
        self.assertIn('effects: effects', snapshots[0])
        self.assertLess(shutter.index('effects: effects'), shutter.index('camera.captureProRAW'))
        self.assertIn('[capturedRecipe, export]', shutter)
        self.assertEqual(stored_members(self.content, 'struct PendingCapturedPhoto:')['recipe'][:2],
                         ('let', 'ProcessingRecipe'))
        self.assertEqual(stored_members(self.pipeline, 'struct ProcessedImage:')['recipe'][:2],
                         ('let', 'ProcessingRecipe'))
        importer = body(self.content, 'private func beginImport(')
        self.assertIn('let settings = explicitRecipe ?? recipe', importer)
        self.assertIn('ImagePipeline.process(input, recipe: settings)', importer)
        self.assertIn('ImagePipeline.writeHEIF(processed,', body(self.content, 'private func deliver('))

    def test_live_cache_identity_changes_for_every_flag_but_stays_pointwise_only(self):
        self.assertEqual(stored_members(self.live, 'struct LiveColorRecipe:')['effects'],
                         ('let', 'EffectToggles', ''))
        self.assertIn('effects: effects', body(self.camera, 'private var liveRecipe:'))
        self.assertIn('cache.firstIndex { $0.recipe == request.recipe }', self.live)
        self.assertIn('self.recipe != recipe', body(self.live, 'func update(source:'))
        bake = body(self.live, 'private func bake(')
        self.assertIn('ffcs_process_linear_rgb_color_only(', bake)
        self.assertNotIn('ffcs_process_linear_rgb_optimized(', bake)
        self.assertNotIn('applySpatial', bake)
        self.assertIn('!["PROVIA", "ACROS"].contains', body(self.live, 'var unsupportedReason:'))

    def test_crop_switch_drives_camera_before_after_and_final_output_from_same_recipe(self):
        self.assertIn('cropToSquare: colorMode == .hncs && hncs.crop(effects: effects) == .centeredSquare', self.camera)
        process = body(self.pipeline, 'static func process(')
        self.assertIn('recipe.crop.resolve(width: input.width, height: input.height)', process)
        self.assertIn('input.original.cropped(to: crop)', process)
        self.assertIn('comparisonSource: comparisonSource', process)
        export = body(self.pipeline, 'private static func exportFullSource(')
        self.assertIn('recipe.crop.resolve(width: sourceWidth, height: sourceHeight)', export)
        self.assertIn('settings.dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: recipe.crop)', export)
        self.assertIn('decoded.cropped(to: crop.ciRect)', export)
        self.assertLess(export.index('recipe.crop.resolve'), export.index('settings.dimensions'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
