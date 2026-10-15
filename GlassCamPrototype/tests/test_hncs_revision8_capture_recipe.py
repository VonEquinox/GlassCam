"""Late capture callback recipe specification and scoped Swift wiring checks.

The executable model composes the existing terminal-capture contract with an
editor recipe snapshot. It is not AVCapture/Swift execution. Source tests bind
shutter, callback, import, and editor-coherence ordering to the implementation.
"""
import copy
from dataclasses import dataclass, field
import re
import unittest

from capture_lifecycle_model import CaptureLifecycleModel
from test_hncs_revision8_source import body, compact, source


def square_recipe():
    return {'mode': 'hncs', 'exposureEV': .5, 'illuminantKelvin': 6500,
            'simulationIndex': 3, 'seed': 0,
            'hncs': {'renderRevision': 8, 'presetKey': 'square-crop', 'filmCurve': 7,
                     'rawFilmCurveType': 2, 'workingSpace': 'lstar', 'intent': 'standard',
                     'factoryKelvinOverride': 4500, 'applyToneCurve': False},
            'effects': {'applyGrain': True, 'applySharpness': False, 'applyExtraCrop': True}}


@dataclass
class EditorRecipeModel:
    controls: dict = field(default_factory=square_recipe)
    busy: bool = False
    operation: int = 0
    pending: tuple | None = None
    rendered: dict | None = None
    source_retained: bool = False
    attempted_dismiss_renders: int = 0
    capture_slot_held: bool = False

    def begin_import(self, explicit_recipe=None):
        # Install busy/generation first: adopting controls can queue observers.
        self.operation += 1
        self.busy = True
        recipe = copy.deepcopy(explicit_recipe if explicit_recipe is not None else self.controls)
        self.pending = self.operation, recipe
        if explicit_recipe is not None:
            self.controls = copy.deepcopy(explicit_recipe)
        return self.operation

    def dismiss(self):
        self.attempted_dismiss_renders += 1
        if self.capture_slot_held or self.busy or self.rendered == self.controls:
            return None
        return self.begin_import()

    def finish(self, operation):
        if self.pending is None or operation != self.operation:
            return False
        self.source_retained = True
        self.capture_slot_held = False
        self.rendered = copy.deepcopy(self.pending[1])
        self.pending = None
        self.busy = False
        return True

    @property
    def can_deliver(self):
        return self.rendered is not None and not self.busy and self.rendered == self.controls


class LateCaptureRecipeModelTests(unittest.TestCase):
    def committed_shutter(self):
        camera, editor = CaptureLifecycleModel(), EditorRecipeModel()
        captured_recipe = copy.deepcopy(editor.controls)
        editor.capture_slot_held = True
        ticket = camera.shutter(target=24)
        camera.did_process_photo(ticket)
        camera.did_finish_capture(ticket)
        return camera, editor, ticket, captured_recipe

    def test_late_committed_photo_after_close_keeps_every_shutter_field_and_square_crop(self):
        camera, editor, ticket, captured = self.committed_shutter()
        camera.stop()
        self.assertEqual(camera.deliveries[ticket], ['DNG'])
        editor.controls['mode'] = 'ffcs'
        editor.controls['exposureEV'] = -2
        editor.controls['illuminantKelvin'] = 2850
        editor.controls['simulationIndex'] = 12
        editor.controls['hncs'].update(presetKey='standard', filmCurve=0,
                                       workingSpace='legacy', intent='reproduction',
                                       factoryKelvinOverride=None, applyToneCurve=True)
        editor.controls['effects'].update(applyGrain=False, applySharpness=True, applyExtraCrop=False)
        # A terminal success may be delivered after Close and these editor changes.
        operation = editor.begin_import(explicit_recipe=captured)
        self.assertEqual(editor.controls, captured)
        self.assertFalse(editor.can_deliver)
        self.assertTrue(editor.finish(operation))
        self.assertEqual(editor.rendered, captured)
        self.assertEqual(editor.rendered['hncs']['presetKey'], 'square-crop')
        self.assertEqual(camera.output_target, 24)
        self.assertTrue(editor.can_deliver)

    def test_on_dismiss_and_control_observers_cannot_retarget_busy_capture_import(self):
        camera, editor, ticket, captured = self.committed_shutter()
        camera.stop()
        editor.controls['hncs']['presetKey'] = 'standard'
        # onDismiss can run before retention, but the held reservation suppresses it.
        previous = editor.operation
        self.assertIsNone(editor.dismiss())
        operation = editor.begin_import(explicit_recipe=captured)
        self.assertIsNone(editor.dismiss())
        self.assertIsNone(editor.dismiss())
        self.assertFalse(editor.finish(previous))
        self.assertTrue(editor.finish(operation))
        self.assertEqual(editor.rendered, captured)
        self.assertEqual(editor.controls, captured)
        self.assertTrue(editor.can_deliver)

    def test_edits_after_callback_do_not_mutate_frozen_render_and_pause_delivery(self):
        _, editor, _, captured = self.committed_shutter()
        operation = editor.begin_import(explicit_recipe=captured)
        editor.controls['hncs']['presetKey'] = 'daylight'
        editor.controls['hncs']['factoryKelvinOverride'] = 3000
        self.assertTrue(editor.finish(operation))
        self.assertEqual(editor.rendered, captured)
        self.assertFalse(editor.can_deliver)
        self.assertTrue(editor.source_retained)
        # Export always consumes rendered's snapshot; changed editor settings need
        # a fresh successful render instead of silently changing this photo.
        self.assertEqual(editor.rendered['hncs']['presetKey'], 'square-crop')

    def test_close_without_terminal_success_still_rejects_photo_and_recipe(self):
        for has_processed_callback in [False, True]:
            camera, editor = CaptureLifecycleModel(), EditorRecipeModel()
            ticket = camera.shutter()
            if has_processed_callback:
                camera.did_process_photo(ticket)
            camera.stop()
            camera.did_finish_capture(ticket)
            self.assertEqual(camera.deliveries[ticket], ['cancelled'])
            self.assertIsNone(editor.pending)
            self.assertIsNone(editor.rendered)
            self.assertFalse(editor.can_deliver)

    def test_imports_without_explicit_capture_recipe_freeze_current_editor_controls(self):
        editor = EditorRecipeModel()
        expected = copy.deepcopy(editor.controls)
        operation = editor.begin_import()
        editor.controls['hncs']['presetKey'] = 'standard'
        self.assertTrue(editor.finish(operation))
        self.assertEqual(editor.rendered, expected)
        self.assertFalse(editor.can_deliver)


class LateCaptureRecipeSourceContracts(unittest.TestCase):
    def assertOrdered(self, text, *items):
        offset = 0
        for item in items:
            index = text.find(item, offset)
            self.assertGreaterEqual(index, 0, f'{item!r} absent after offset {offset}')
            offset = index + len(item)

    def test_shutter_snapshots_complete_recipe_before_camera_submission(self):
        view = source('CameraView.swift')
        shutter = body(view, 'private func shutter(')
        self.assertIn('let onCapture: (Data, ExportSettings, ProcessingRecipe) -> Void', view)
        self.assertOrdered(shutter,
                           'guard camera.isReady, !camera.isCapturing, let output = selectedOutput',
                           'let export = ExportSettings(',
                           'let capturedRecipe = ProcessingRecipe(',
                           'camera.captureProRAW { [capturedRecipe, export] result in',
                           'case .success(let data): onCapture(data, export, capturedRecipe)')
        snapshot = compact(shutter.split('let capturedRecipe = ProcessingRecipe(', 1)[1].split('camera.captureProRAW', 1)[0])
        fields = dict(re.findall(r'(mode|exposureEV|illuminantKelvin|simulationIndex|seed|hncs|effects):\s*(\w+)', snapshot))
        self.assertEqual(fields, {'mode': 'colorMode', 'exposureEV': 'exposureEV',
                                  'illuminantKelvin': 'illuminantKelvin',
                                  'simulationIndex': 'simulationIndex', 'seed': '0', 'hncs': 'hncs', 'effects': 'effects'})
        callback = body(shutter, 'camera.captureProRAW')
        self.assertNotIn('ProcessingRecipe(', callback)
        self.assertNotIn('selectedOutput', callback)
        self.assertNotIn('if !isClosing { onCapture', callback)
        self.assertIn('if !isClosing { captureError = error.localizedDescription }', callback)

    def test_late_capture_recipe_is_forwarded_to_import_without_sampling_current_controls(self):
        content = source('ContentView.swift')
        capture = body(content, 'func selectCapture(')
        self.assertOrdered(capture, 'SourceImageFile(data: data, fileExtension: "dng")',
                           'PendingCapturedPhoto(ticket: ticket, storage: storage,',
                           'exportSettings: settings, recipe: capturedRecipe, warning: warning)',
                           'importRetainedCapture(retained)')
        retained = body(content, 'private func importRetainedCapture(')
        self.assertIn('beginImport(exportSettings: retained.exportSettings, explicitRecipe: retained.recipe,', retained)
        importer = body(content, 'private func beginImport(')
        self.assertOrdered(importer, 'let settings = explicitRecipe ?? recipe',
                           'importTask = Task', 'ImagePipeline.load(data:',
                           'exportSettings: exportSettings)',
                           'ImagePipeline.process(input, recipe: settings)')
        self.assertNotIn('ImagePipeline.process(input, recipe: recipe)', importer)
        self.assertGreaterEqual(importer.count('guard operationID == id, !Task.isCancelled else { return }'), 3)
        # Ordinary imports have no capture snapshot and preserve their current-controls path.
        self.assertIn('explicitRecipe: ProcessingRecipe? = nil', content)
        self.assertIn('beginImport {', body(content, 'func selectPhoto('))
        self.assertIn('beginImport {', body(content, 'func selectFile('))

    def test_busy_and_generation_are_installed_before_publishing_captured_controls(self):
        content = source('ContentView.swift')
        importer = body(content, 'private func beginImport(')
        self.assertOrdered(importer, 'importTask?.cancel()', 'cancelImageWorker?()',
                           'operationID = id', 'busy = true',
                           'let settings = explicitRecipe ?? recipe',
                           'if explicitRecipe != nil { adoptRecipeSnapshot(settings) }',
                           'importTask = Task')
        adopted = body(content, 'private func adoptRecipeSnapshot(')
        assignments = dict(re.findall(r'(colorMode|simulationIndex|exposure|kelvin|hncs|effects)\s*=\s*snapshot\.(\w+)', adopted))
        self.assertEqual(assignments, {'colorMode': 'mode', 'simulationIndex': 'simulationIndex',
                                      'exposure': 'exposureEV', 'kelvin': 'illuminantKelvin', 'hncs': 'hncs', 'effects': 'effects'})
        self.assertIn('guard let input = imported, !busy else { return }', body(content, 'func render() async'))
        self.assertIn('processed?.recipe != recipe', content)
        self.assertIn('processed != nil && !busy && !hasPendingChanges', content)

    def test_dismissal_is_session_scoped_and_skips_rerender_while_capture_slot_held(self):
        content = source('ContentView.swift')
        callback = body(content, 'onCapture: {')
        self.assertOrdered(callback,
                           'model.selectCapture(data, settings: settings, capturedRecipe: capturedRecipe, ticket: sessionTicket)',
                           'if cameraSession?.id == sessionTicket { cameraSession = nil }')
        self.assertNotIn('Task', callback)
        dismissal = body(content, 'onDismiss: {')
        self.assertIn('if model.captureSlotAvailable { Task { await model.renderIfNeeded() } }', dismissal)
        self.assertIn('if hasPendingChanges { await render() }', body(content, 'func renderIfNeeded()'))
        close = body(source('CameraView.swift'), 'private func closeCamera()')
        self.assertOrdered(close, 'isClosing = true', 'camera.stop()', 'onClose()')
        self.assertNotIn('capturedRecipe', close)


if __name__ == '__main__':
    unittest.main(verbosity=2)
