"""Revision-8 integration dataflow/ownership contracts, not a Swift compilation.

Checks are scoped to declarations and method bodies, including equality and
Codable migration, cache keys, frozen recipes, ordered fail-closed transitions,
and common crop coordinates. Executable reference and geometry tests are kept
separately; Apple SDK/device testing remains required.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    # Assertions must be implemented code, not promises left in comments.
    text = (ROOT / 'ios/GlassCam' / name).read_text()
    return re.sub(r'//[^\n]*', '', text)


def body(text, marker):
    start = text.index('{', text.index(marker))
    depth = 1
    for i in range(start + 1, len(text)):
        depth += (text[i] == '{') - (text[i] == '}')
        if depth == 0:
            return text[start + 1:i]
    raise AssertionError('Unterminated Swift declaration: ' + marker)


def stored_members(text, marker):
    result = {}
    depth = 0
    for line in body(text, marker).splitlines():
        if depth == 0:
            match = re.match(r'\s*(let|var)\s+(\w+)\s*(:[^={]+)?\s*(?:=([^{}]*))?\s*$', line)
            if match:
                result[match.group(2)] = (match.group(1), (match.group(3) or '').strip(': '),
                                         (match.group(4) or '').strip())
        depth += line.count('{') - line.count('}')
    return result


def compact(text):
    return re.sub(r'\s+', ' ', text).strip()


class Revision8IntegrationSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = source('HNCSEngine.swift')
        cls.pipeline = source('ImagePipeline.swift')
        cls.content = source('ContentView.swift')
        cls.settings = source('CameraSettingsStore.swift')
        cls.workflow = source('CaptureWorkflow.swift')
        cls.proxy = source('LiveColorProxy.swift')
        cls.view = source('CameraView.swift')
        cls.export = source('ExportSettings.swift')
        cls.preview = source('PreviewRaster.swift') + source('PrecisionPreview.swift')
        cls.framing = source('CameraFraming.swift')

    def assertOrdered(self, text, *items):
        position = 0
        for item in items:
            found = text.find(item, position)
            self.assertGreaterEqual(found, 0, f'{item!r} absent after offset {position}')
            position = found + len(item)

    def test_synthesized_recipe_identity_and_persistence_include_every_hncs_choice(self):
        self.assertRegex(self.engine, r'struct HNCSSettings:\s*Codable,\s*Equatable,\s*Sendable')
        members = stored_members(self.engine, 'struct HNCSSettings:')
        expected = {'renderRevision', 'presetKey', 'filmCurve', 'rawFilmCurveType',
                    'workingSpace', 'intent', 'factoryKelvinOverride', 'applyToneCurve'}
        self.assertEqual(set(members), expected)
        settings = body(self.engine, 'struct HNCSSettings:')
        # HNCS fields now have explicit backward-compatible decoding, while
        # synthesized equality and encoding still cover the complete payload.
        coding_keys = body(settings, 'private enum CodingKeys:')
        for field in expected:
            self.assertRegex(coding_keys, r'\b' + field + r'\b')
            self.assertIn('forKey: .' + field, body(settings, 'init(from decoder:'))
        self.assertNotIn('func ==', settings)
        self.assertNotIn('func encode(', settings)
        self.assertEqual(members['presetKey'][2], '"standard"')
        self.assertEqual(members['filmCurve'][2], '.asShot')
        self.assertEqual(members['rawFilmCurveType'][2], '2')
        self.assertEqual(members['factoryKelvinOverride'][2], 'nil')
        recipe = stored_members(self.pipeline, 'struct ProcessingRecipe:')
        self.assertEqual(set(recipe), {'mode', 'exposureEV', 'illuminantKelvin', 'simulationIndex', 'seed', 'hncs', 'effects', 'ffcs', 'photoWhiteBalance'})
        self.assertTrue(all(member[0] == 'let' for member in recipe.values()))
        self.assertEqual(recipe['hncs'][1], 'HNCSSettings')
        self.assertEqual(recipe['effects'][1], 'EffectToggles')
        self.assertRegex(self.pipeline, r'struct ProcessingRecipe:\s*Codable,\s*Equatable,\s*Sendable')

    def test_settings_restore_as_one_validated_recipe_and_all_controls_persist(self):
        init = body(self.settings, 'init(defaults: UserDefaults')
        self.assertOrdered(init, 'defaults.data(forKey: Self.recipeKey)',
                           'JSONDecoder().decode(ProcessingRecipe.self, from: data)',
                           'saved.isValid', 'colorMode = saved.mode')
        assignments = dict(re.findall(r'(colorMode|simulationIndex|exposure|kelvin|hncs|effects)\s*=\s*saved\.(\w+)', init))
        self.assertEqual(assignments, {'colorMode': 'mode', 'simulationIndex': 'simulationIndex',
                                      'exposure': 'exposureEV', 'hncs': 'hncs', 'effects': 'effects'})
        for control in assignments:
            self.assertRegex(self.settings, r'@Published var ' + control + r'[^\n]*\{ didSet \{ persistRecipe\(\) \} \}')
        persist = body(self.settings, 'private func persistRecipe()')
        self.assertOrdered(persist, 'guard recipe.isValid', 'JSONEncoder().encode(recipe)',
                           'defaults.set(data, forKey: Self.recipeKey)')
        self.assertIn('editor.processingRecipe.revision8.v1', self.settings)
        valid = body(self.engine, 'var isValid: Bool')
        self.assertIn('renderRevision == Self.currentRenderRevision', valid)
        self.assertIn('rawFilmCurveType == 2', valid)
        self.assertIn('HNCSEngine.presets.contains { $0.id == presetKey }', valid)

    def test_context_cache_matches_complete_settings_and_retains_inflight_owner(self):
        members = stored_members(self.engine, 'private struct ContextKey:')
        self.assertEqual({key: value[1] for key, value in members.items()},
                         {'exposure': 'Double', 'captureKelvin': 'Double', 'whiteBalance': 'PhotoWhiteBalance?', 'settings': 'HNCSSettings', 'effects': 'EffectToggles'})
        cache = body(self.engine, 'private final class ContextCache:')
        self.assertOrdered(cache, 'lock.lock()',
                           'ContextKey(exposure: exposure, captureKelvin: kelvin, whiteBalance: whiteBalance, settings: settings, effects: effects)',
                           'cached.key == key', 'ContextOwner(key: key)', 'cached = owner')
        self.assertNotRegex(cache, r'cached\.(?:exposure|kelvin)\s*==')
        for signature in ['static func process(', 'static func exportLinearRGBA(']:
            method = body(self.engine, signature)
            self.assertOrdered(method, 'contextCache.context(exposure: exposureEV, kelvin: illuminantKelvin, settings: settings, effects: effects, whiteBalance: whiteBalance)',
                               'let context = owner.pointer', 'withExtendedLifetime(owner)', 'withUnsafeBufferPointer')
        self.assertIn('deinit { hncs_destroy(pointer) }', self.engine)

    def test_bridge_keeps_capture_factory_and_target_wb_separate(self):
        constructor = compact(body(self.engine, 'init(key: ContextKey)'))
        self.assertIn('hncs_create_preset(key.exposure, key.captureKelvin, settings.factoryKelvinOverride ?? 0,', constructor)
        self.assertIn('settings.presetKey.withCString { preset in', constructor)
        self.assertIn('settings.workingSpace == .lstar ? 1 : 0', constructor)
        self.assertIn('settings.intent == .reproduction ? 1 : 0', constructor)
        self.assertIn('Int32(settings.filmCurve.rawValue), Int32(settings.rawFilmCurveType)', constructor)
        self.assertIn('preset, settings.applyToneCurve ? 1 : 0, nil, nil)', constructor)
        # Target gain semantics live in the revision-8 backend. The developed RGB
        # bridge cannot multiply gains into input or alias the two CCT controls.
        self.assertNotRegex(constructor, r'key\.captureKelvin\s*=|factoryKelvinOverride\s*=')
        process = body(self.pipeline, 'static func process(')
        self.assertNotRegex(process, r'(?:native_wb|target_wb|whiteBalanceGain)')
        controls = body(self.content, 'struct HNCSPresetControls:')
        self.assertIn('selection: $settings.presetKey', controls)
        self.assertIn('settings.factoryKelvinOverride = $0', controls)
        self.assertNotIn('model.kelvin', controls)
        self.assertIn('LabeledContent("White balance", value: "Automatic from photo"', self.view)
        self.assertIn('Stepper("Factory CCT:', controls)

    def test_import_and_rerender_freeze_recipe_before_background_work(self):
        self.assertIn('let snapshot = CaptureSnapshot(recipe: settings.recipe, output: export)', self.view)
        self.assertIn('ImagePipeline.writeHEIF(sourceFile: input, recipe: snapshot.recipe', self.workflow)
        self.assertIn('settings: snapshot.output', self.workflow)
        self.assertIn('let snapshot: CaptureSnapshot', self.workflow)
        self.assertEqual(stored_members(self.pipeline, 'struct ProcessedImage:')['recipe'][:2], ('let', 'ProcessingRecipe'))

    def test_preview_and_export_dispatch_the_same_frozen_hncs_recipe(self):
        preview = compact(body(self.pipeline, 'static func process('))
        export = compact(body(self.pipeline, 'private static func exportFullSource('))
        self.assertIn('recipe: recipe)', preview)
        self.assertIn('recipe: processed.recipe', self.pipeline)
        self.assertIn('guard recipe.isValid', export)
        for method in [preview, export]:
            self.assertIn('exposureEV: recipe.exposureEV', method)
            self.assertIn('illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs', method)
            self.assertNotIn('settings: .standard', method)
            self.assertNotIn('UserDefaults', method)
        self.assertIn('ImagePipeline.writeHEIF(sourceFile: input, recipe: snapshot.recipe', self.workflow)

    def test_live_cube_identity_has_full_hncs_settings_and_new_contract(self):
        recipe = stored_members(self.proxy, 'struct LiveColorRecipe:')
        self.assertEqual(recipe['hncs'][:2], ('let', 'HNCSSettings'))
        self.assertIn('revision10-native-sharpness', recipe['contract'][2])
        self.assertIn('cache.firstIndex { $0.recipe == request.recipe }', self.proxy)
        view = body(self.view, 'private var liveRecipe:')
        self.assertIn('hncs: colorMode == .hncs ? hncs : .standard', view)
        self.assertIn('illuminantKelvin: 5500', view)
        gate = body(self.proxy, 'var unsupportedReason:')
        self.assertIn('if mode == .hncs {', gate)
        self.assertIn('Showing system preview.', gate)
        # Full-struct equality also excludes a changed tone/WB/revision even if
        # the preset's display name still says Standard.
        self.assertNotIn('hncs.presetKey == "standard"', gate)

    def test_unsupported_live_recipe_revokes_old_cube_before_any_request(self):
        update = body(self.proxy, 'func update(source:')
        self.assertOrdered(update, 'self.recipe != recipe', 'self.source?.setEnabled(false)',
                           'revision &+= 1', 'hidePresentation()', 'cubes.cancel()',
                           'cube = nil; cubeFilter = nil', 'self.recipe = recipe',
                           'if let reason = recipe.unsupportedReason { fail(reason); return }',
                           'source.setEnabled(hasWindow)', 'cubes.request(recipe)')
        fail = body(self.proxy, 'private func fail(')
        self.assertOrdered(fail, 'active = false', 'hidePresentation()', 'cubes.cancel()',
                           'cube = nil; cubeFilter = nil', 'source?.setEnabled(false)')
        hide = body(self.proxy, 'private func hidePresentation()')
        self.assertIn('view?.alpha = 0', hide)
        bake = body(self.proxy, 'private func bake(')
        self.assertOrdered(bake, 'recipe.unsupportedReason', 'throw LiveProxyFailure.unavailable',
                           'var rgba =', 'hncs_create(')
        # Raw source layer remains under the proxy; unsupported settings leave it
        # available rather than displaying a Standard cube under a different label.
        self.assertLess(self.view.index('if let layer = camera.centerPreviewLayer'),
                        self.view.index('LiveColorProxy(source:'))
        self.assertIn('self.revision == ticket', update)

    def test_preview_crop_and_before_after_share_exact_pixel_rectangle(self):
        process = body(self.pipeline, 'static func process(')
        self.assertOrdered(process, 'recipe.crop.resolve(width: input.width, height: input.height)',
                           'input.original.cropped(to: crop)', 'for row in crop.top..<(crop.top + crop.height)',
                           '(row * input.width + crop.x) * 3', 'switch recipe.mode',
                           'PreviewRaster(linearRGBA: rgba, width: crop.width, height: crop.height)',
                           'comparisonSource: comparisonSource')
        self.assertIn('start..<(start + crop.width * 3)', process)
        self.assertIn('linearSRGB: effectInput, width: crop.width', process)
        original = body(self.preview, 'func cropped(to crop: PixelCrop)')
        self.assertOrdered(original, 'crop.ciY + crop.height <= height',
                           'image.cropped(to: crop.ciRect)',
                           'translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)',
                           'width: crop.width, height: crop.height,',
                           'headroom: headroom, storage: storage')
        self.assertIn('PrecisionPreview(source: capture.preview)', self.view)

    def test_export_resolves_full_source_crop_before_output_selection_and_processing(self):
        export = body(self.pipeline, 'private static func exportFullSource(')
        self.assertOrdered(export, 'fullSourceImage(sourceFile, whiteBalance: whiteBalance, rawDecode: rawDecode)',
                           'let sourceWidth = Int(decoded.extent.width.rounded(.down))',
                           'let sourceHeight = Int(decoded.extent.height.rounded(.down))',
                           'guard recipe.isValid',
                           'recipe.crop.resolve(width: sourceWidth, height: sourceHeight)',
                           'let width = crop.width, height = crop.height',
                           'settings.dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: recipe.crop)',
                           'let rasterBytes = width * height * 16',
                           'decoded.cropped(to: crop.ciRect)',
                           'translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)',
                           'for start in stride(', 'HNCSEngine.', 'CILanczosScaleTransform',
                           'writeHEIF10Representation')
        self.assertNotIn('processed.source.linearRGB', export)
        self.assertNotIn('processed.image', export)
        self.assertIn('Double(output.height) / Double(height)', export)
        self.assertIn('kCIInputAspectRatioKey: 1.0', export)

    def test_swift_crop_formulas_match_integer_model_and_validate_uncropped_target(self):
        resolve = body(self.export, 'func resolve(width:')
        self.assertOrdered(resolve, 'guard width > 0, height > 0', 'let side = min(width, height)',
                           'self == .centeredSquare ? side : width', 'self == .centeredSquare ? side : height',
                           'x: (width - cropWidth) / 2', 'top: (height - cropHeight) / 2')
        self.assertIn('sourceHeight - top - height', body(self.export, 'var ciY: Int'))
        dimensions = body(self.export, 'func dimensions(sourceWidth:')
        self.assertOrdered(dimensions, 'let swap =', 'let width = swap ?', 'let height = swap ?',
                           'width <= sourceWidth, height <= sourceHeight',
                           'Double(sourceWidth) / Double(sourceHeight)',
                           'let result = try crop.resolve(width: width, height: height)',
                           'return (result.width, result.height)')
        recipe_crop = body(self.pipeline, 'var crop: ImageCrop')
        self.assertEqual(compact(recipe_crop), 'mode == .hncs ? hncs.crop(effects: effects) : .none')

    def test_camera_square_frame_clips_unstretched_source(self):
        framing = body(self.framing, 'init(size:')
        self.assertOrdered(framing, 'let outputAspect: CGFloat = cropToSquare ? 1 : aspect',
                           'min(width, height * outputAspect)',
                           'photoWidth / outputAspect',
                           'photoWidth * max(1, aspect)', 'photoHeight * max(1, 1 / aspect)',
                           'sourcePhoto = CGRect(')
        self.assertNotIn('photoHeight * ratio', framing)
        self.assertNotIn('photoWidth * ratio', framing)
        center = self.view.split('if let layer = camera.centerPreviewLayer', 1)[1].split('PhotoFrameGuide', 1)[0]
        self.assertEqual(center.count('.frame(width: framing.sourcePhoto.width, height: framing.sourcePhoto.height)'), 2)
        self.assertEqual(center.count('.frame(width: framing.photo.width, height: framing.photo.height)'), 2)
        self.assertEqual(center.count('.clipped()'), 2)
        self.assertNotIn('.resizeAspectFill', center)
        self.assertIn('cropToSquare: colorMode == .hncs && hncs.crop(effects: effects) == .centeredSquare', self.view)


if __name__ == '__main__':
    unittest.main(verbosity=2)
