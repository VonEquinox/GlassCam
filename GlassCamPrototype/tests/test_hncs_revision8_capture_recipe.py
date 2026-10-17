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


class CaptureRecipeSourceContracts(unittest.TestCase):
    def test_snapshot_is_forwarded_to_full_source_processing(self):
        workflow = source('CaptureWorkflow.swift')
        self.assertIn('let snapshot: CaptureSnapshot', workflow)
        self.assertIn('ImagePipeline.writeHEIF(sourceFile: input, recipe: snapshot.recipe', workflow)
        self.assertIn('settings: snapshot.output', workflow)
        self.assertIn('settings: snapshot.output', workflow)
        self.assertNotIn('UserDefaults', workflow)

    def test_root_owns_shared_settings_and_workflow(self):
        content = source('ContentView.swift')
        self.assertIn('@StateObject private var settings = CameraSettingsStore()', content)
        self.assertIn('@StateObject private var workflow = CaptureWorkflow(', content)
        self.assertIn('CameraView(settings: settings, workflow: workflow)', content)
        self.assertNotIn('EditorModel', content)


if __name__ == '__main__':
    unittest.main(verbosity=2)
