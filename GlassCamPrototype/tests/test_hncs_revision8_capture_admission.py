"""Executable specification for bounded late-capture ownership and admission.

A single shutter reservation survives Close and terminal success until the DNG
is safely opened. New imports/exports/sessions invalidate automatic admission;
ordinary effect edits do not. This is a model, not Swift or Apple API execution.
"""
import copy
from dataclasses import dataclass
import unittest

from test_hncs_revision8_capture_recipe import square_recipe
from test_hncs_revision8_source import body, compact, source, stored_members


@dataclass(frozen=True)
class Reservation:
    serial: int
    admission: int
    camera: int
    recipe: dict
    dimensions: tuple


class CaptureAdmissionModel:
    def __init__(self):
        self.controls = square_recipe()
        self.admission = 0
        self.camera = 0
        self.visible_camera = None
        self.next_capture = 0
        self.slot = None
        self.pending = None
        self.retaining = None
        self.operation = 0
        self.busy = False
        self.exporting = False
        self.current_work = None
        self.source = None
        self.processing_pending = None
        self.warning = None

    def begin_camera(self):
        self.admission += 1
        self.camera += 1
        self.visible_camera = self.camera
        return self.camera

    def close_camera(self):
        self.visible_camera = None

    def reserve_shutter(self, camera, dimensions=(4032, 3024)):
        if self.slot is not None or self.visible_camera != camera:
            return None
        self.next_capture += 1
        self.slot = Reservation(self.next_capture, self.admission, camera,
                                copy.deepcopy(self.controls), dimensions)
        return self.slot

    def begin_new_work(self, kind):
        self.admission += 1
        self.operation += 1
        self.busy = True
        self.exporting = kind == 'export'
        self.current_work = kind
        return self.operation

    def terminal_failure(self, reservation):
        if self.slot == reservation and self.pending is None and self.retaining is None:
            self.slot = None

    def start_retention(self, reservation, data=b'genuine completed DNG'):
        if self.slot != reservation or self.pending is not None or self.retaining is not None:
            return False
        self.retaining = reservation, data
        if self.visible_camera == reservation.camera:
            self.visible_camera = None
        return True

    def finish_retention(self, disk_ok=True):
        if self.retaining is None:
            return False
        reservation, data = self.retaining
        self.pending = {'reservation': reservation, 'storage': 'file' if disk_ok else 'data',
                        'payload': data, 'recipe': copy.deepcopy(reservation.recipe),
                        'dimensions': reservation.dimensions}
        self.retaining = None
        if not disk_ok:
            self.warning = 'Retained capture in memory because storage failed'
        # Admission is checked after asynchronous disk work, not on callback entry.
        admitted = reservation.admission == self.admission and not self.exporting
        if admitted:
            self._open_pending()
        return admitted

    def terminal_success(self, reservation, data=b'genuine completed DNG', disk_ok=True):
        if not self.start_retention(reservation, data):
            return False
        return self.finish_retention(disk_ok)

    def _open_pending(self):
        self.operation += 1
        self.busy = True
        self.current_work = 'pending capture'
        self.processing_pending = self.operation
        self.controls = copy.deepcopy(self.pending['recipe'])
        return self.operation

    def open_pending(self):
        if self.busy or self.pending is None:
            return None
        self.admission += 1
        return self._open_pending()

    def finish_open(self, operation, decoded=True):
        if operation != self.operation or self.processing_pending != operation:
            return False
        self.busy = False
        self.processing_pending = None
        if not decoded:
            return False
        self.source = self.pending['payload']
        self.pending = None
        self.slot = None
        return True


class CaptureAdmissionModelTests(unittest.TestCase):
    def queued_capture(self, newer_kind='import', disk_ok=True):
        model = CaptureAdmissionModel()
        camera = model.begin_camera()
        reservation = model.reserve_shutter(camera)
        model.close_camera()
        new_operation = model.begin_new_work(newer_kind)
        return model, reservation, new_operation, disk_ok

    def test_new_import_or_export_is_not_cancelled_or_retargeted_by_late_success(self):
        for kind in ['import', 'export']:
            model, reservation, operation, _ = self.queued_capture(kind)
            model.controls['hncs']['presetKey'] = 'daylight'
            controls = copy.deepcopy(model.controls)
            self.assertFalse(model.terminal_success(reservation))
            self.assertEqual(model.operation, operation)
            self.assertEqual(model.current_work, kind)
            self.assertTrue(model.busy)
            self.assertEqual(model.controls, controls)
            self.assertEqual(model.pending['recipe'], reservation.recipe)
            self.assertEqual(model.pending['dimensions'], (4032, 3024))
            self.assertEqual(model.pending['payload'], b'genuine completed DNG')
            self.assertIsNotNone(model.slot)

    def test_new_camera_can_open_but_old_callback_cannot_dismiss_it_or_admit_second_shot(self):
        model = CaptureAdmissionModel()
        first = model.begin_camera()
        reservation = model.reserve_shutter(first)
        model.close_camera()
        second = model.begin_camera()
        self.assertIsNone(model.reserve_shutter(second))
        self.assertFalse(model.terminal_success(reservation))
        self.assertEqual(model.visible_camera, second)
        self.assertIsNone(model.reserve_shutter(second))
        self.assertEqual(model.pending['reservation'], reservation)
        self.assertEqual(model.next_capture, 1)

    def test_new_work_during_async_file_retention_is_rechecked_before_auto_open(self):
        for kind in ['import', 'export', 'camera']:
            model = CaptureAdmissionModel()
            camera = model.begin_camera()
            reservation = model.reserve_shutter(camera)
            self.assertTrue(model.start_retention(reservation))
            if kind == 'camera':
                new_camera = model.begin_camera()
                operation = model.operation
            else:
                operation = model.begin_new_work(kind)
            controls = copy.deepcopy(model.controls)
            self.assertFalse(model.finish_retention())
            self.assertEqual(model.operation, operation)
            self.assertEqual(model.controls, controls)
            self.assertEqual(model.pending['reservation'], reservation)
            self.assertEqual(model.slot, reservation)
            if kind == 'camera':
                self.assertEqual(model.visible_camera, new_camera)

    def test_reservation_is_released_on_failure_even_after_close(self):
        model = CaptureAdmissionModel()
        camera = model.begin_camera()
        reservation = model.reserve_shutter(camera)
        model.close_camera()
        model.terminal_failure(reservation)
        self.assertIsNone(model.slot)
        self.assertIsNone(model.pending)
        second = model.begin_camera()
        self.assertIsNotNone(model.reserve_shutter(second))
        # An older callback cannot release the new shutter reservation.
        current = model.slot
        model.terminal_failure(reservation)
        self.assertEqual(model.slot, current)

    def test_effect_edits_do_not_invalidate_capture_admission_or_change_shutter_recipe(self):
        model = CaptureAdmissionModel()
        camera = model.begin_camera()
        reservation = model.reserve_shutter(camera)
        model.close_camera()
        model.controls['hncs']['presetKey'] = 'standard'
        model.controls['exposureEV'] = -2
        self.assertTrue(model.terminal_success(reservation))
        self.assertEqual(model.controls, reservation.recipe)
        self.assertEqual(model.pending['recipe']['hncs']['presetKey'], 'square-crop')
        self.assertTrue(model.finish_open(model.operation))
        self.assertIsNone(model.slot)
        self.assertIsNotNone(model.source)

    def test_explicit_open_is_blocked_while_busy_and_releases_only_after_successful_decode(self):
        model, reservation, current_operation, _ = self.queued_capture()
        model.terminal_success(reservation)
        self.assertIsNone(model.open_pending())
        self.assertEqual(model.operation, current_operation)
        model.busy = False
        first_try = model.open_pending()
        self.assertIsNotNone(first_try)
        self.assertFalse(model.finish_open(first_try, decoded=False))
        self.assertIsNotNone(model.pending)
        self.assertEqual(model.slot, reservation)
        second_try = model.open_pending()
        self.assertFalse(model.finish_open(first_try))
        self.assertIsNotNone(model.pending)
        self.assertTrue(model.finish_open(second_try))
        self.assertIsNone(model.pending)
        self.assertIsNone(model.slot)
        self.assertEqual(model.source, b'genuine completed DNG')

    def test_disk_failure_keeps_one_owned_memory_fallback_and_visible_warning(self):
        model, reservation, operation, _ = self.queued_capture('export')
        payload = b'DNG bytes that must not be discarded'
        self.assertFalse(model.terminal_success(reservation, data=payload, disk_ok=False))
        self.assertEqual(model.pending['storage'], 'data')
        self.assertIs(model.pending['payload'], payload)
        self.assertIn('storage failed', model.warning)
        self.assertEqual(model.operation, operation)
        self.assertTrue(model.exporting)
        model.begin_camera()
        self.assertIsNone(model.reserve_shutter(model.camera))
        self.assertFalse(model.terminal_success(reservation, data=b'duplicate'))
        self.assertIs(model.pending['payload'], payload)
        self.assertEqual(model.next_capture, 1)


class CaptureAdmissionSourceContracts(unittest.TestCase):
    def assertOrdered(self, text, *items):
        offset = 0
        for item in items:
            index = text.find(item, offset)
            self.assertGreaterEqual(index, 0, f'{item!r} absent after offset {offset}')
            offset = index + len(item)

    def test_slot_is_reserved_before_submission_and_all_terminal_failures_release_after_close(self):
        content, view = source('ContentView.swift'), source('CameraView.swift')
        reserve = body(content, 'func reserveCaptureDelivery(')
        self.assertOrdered(reserve,
                           'guard captureSlotAvailable, ticket == captureAdmissionGeneration else { return false }',
                           'captureReservation = ticket', 'captureSlotAvailable = false', 'return true')
        shutter = body(view, 'private func shutter(')
        self.assertOrdered(shutter, 'let capturedRecipe = ProcessingRecipe(',
                           'guard reserveCapture() else {',
                           'captureError = "Couldn’t start this photo.', 'return',
                           'camera.captureProRAW', 'case .failure(let error):',
                           'onCaptureFailure()', 'if !isClosing { captureError = error.localizedDescription }')
        self.assertIn('|| !captureSlotAvailable)', shutter)
        self.assertNotIn('onCaptureFailure()', body(view, 'private func closeCamera()'))
        release = body(content, 'func releaseCaptureDelivery(')
        self.assertOrdered(release, 'guard captureReservation == ticket else { return }',
                           'captureReservation = nil', 'captureSlotAvailable = true')

    def test_new_source_export_and_session_invalidate_only_admission(self):
        content = source('ContentView.swift')
        for method, next_step in [('func selectPhoto(', 'beginImport'),
                                  ('func selectFile(', 'beginImport'),
                                  ('private func deliver(', 'operationID = id'),
                                  ('func beginCameraSession()', 'return captureAdmissionGeneration')]:
            scope = body(content, method)
            self.assertOrdered(scope, 'captureAdmissionGeneration = UUID()', next_step)
            self.assertNotIn('releaseCaptureDelivery(', scope)
            self.assertNotIn('captureReservation = nil', scope)
            self.assertNotIn('pendingCapture = nil', scope)
        for method in ['func render() async', 'private func persistRecipe()', 'private func adoptRecipeSnapshot(']:
            self.assertNotIn('captureAdmissionGeneration', body(content, method))

    def test_async_retention_rechecks_admission_after_disk_work_without_cancelling_new_work(self):
        content = source('ContentView.swift')
        capture = body(content, 'func selectCapture(')
        self.assertOrdered(capture, 'isRetainingCapture = true', 'Task { @MainActor in',
                           'try await Task.detached', 'SourceImageFile(data: data, fileExtension: "dng")',
                           '}.value', 'PendingCapturedPhoto(', 'pendingCapture = retained',
                           'isRetainingCapture = false',
                           'if ticket == captureAdmissionGeneration', 'importRetainedCapture(retained)')
        gate = body(capture, 'if ticket == captureAdmissionGeneration')
        self.assertEqual(compact(gate), 'importRetainedCapture(retained)')
        for forbidden in ['operationID =', 'busy =', 'importTask?.cancel()', 'exportTask?.cancel()',
                          'exportWork?.cancel()', 'adoptRecipeSnapshot(', 'beginImport(']:
            self.assertNotIn(forbidden, capture)

    def test_one_pending_owner_keeps_file_or_memory_plus_frozen_output_and_recipe(self):
        content = source('ContentView.swift')
        pending = body(content, 'struct PendingCapturedPhoto:')
        self.assertIn('case file(SourceImageFile)', pending)
        self.assertIn('case memory(Data)', pending)
        members = stored_members(content, 'struct PendingCapturedPhoto:')
        for name, kind in [('ticket', 'UUID'), ('storage', 'Storage'),
                           ('exportSettings', 'ExportSettings'), ('recipe', 'ProcessingRecipe')]:
            self.assertEqual(members[name][:2], ('let', kind))
        self.assertIn('@Published private(set) var pendingCapture: PendingCapturedPhoto?', content)
        self.assertNotIn('[PendingCapturedPhoto]', content)
        capture = body(content, 'func selectCapture(')
        self.assertOrdered(capture, 'catch {', 'storage = .memory(data)',
                           'warning = "Couldn’t retain the completed photo on disk:',
                           'pendingCapture = retained')
        self.assertIn('It’s temporarily kept in memory. Open it before closing the app.', capture)
        self.assertIn('if let warning = pending.warning { Text(warning).foregroundStyle(.orange) }', content)

    def test_pending_open_is_explicit_busy_guarded_and_consumed_only_after_source_is_owned(self):
        content = source('ContentView.swift')
        opened = body(content, 'func openPendingCapture()')
        self.assertOrdered(opened, 'guard !busy, let pendingCapture else { return }',
                           'importRetainedCapture(pendingCapture)')
        self.assertIn('Button("Open captured photo", action: model.openPendingCapture).disabled(model.busy)', content)
        retained = body(content, 'private func importRetainedCapture(')
        self.assertOrdered(retained, 'captureAdmissionGeneration = UUID()',
                           'beginImport(exportSettings: retained.exportSettings, explicitRecipe: retained.recipe,',
                           'onSourceRetained:', 'self.pendingCapture?.id == retained.id',
                           'self.pendingCapture = nil', 'self.releaseCaptureDelivery(ticket: retained.ticket)')
        importer = body(content, 'private func beginImport(')
        self.assertOrdered(importer, 'let input = try await decode.value',
                           'guard operationID == id, !Task.isCancelled else { return }',
                           'imported = input', 'onSourceRetained?()', 'let rendering = Task.detached')
        self.assertEqual(importer.count('onSourceRetained?()'), 1)
        for forbidden in ['pendingCapture = nil', 'releaseCaptureDelivery(']:
            self.assertNotIn(forbidden, importer)
        self.assertIn('case .file(let file):', retained)
        self.assertIn('Data(contentsOf: file.url)', retained)
        self.assertIn('case .memory(let data): return (data, "dng")', retained)

    def test_old_session_callbacks_cannot_dismiss_new_camera_or_reuse_its_ticket(self):
        content = source('ContentView.swift')
        cover = content.split('.fullScreenCover(', 1)[1].split('.sheet(item: $model.fileSave)', 1)[0]
        self.assertIn('@State private var cameraSession: CameraSession?', content)
        self.assertIn('cameraSession = CameraSession(id: model.beginCameraSession())', content)
        self.assertIn('item: $cameraSession', cover)
        self.assertIn('}) { session in', cover)
        self.assertIn('let sessionTicket = session.id', cover)
        self.assertNotIn('cameraTicket', content)
        self.assertNotIn('cameraPresented', content)
        self.assertIn('reserveCapture: { model.reserveCaptureDelivery(ticket: sessionTicket) }', cover)
        self.assertIn('onCaptureFailure: { model.releaseCaptureDelivery(ticket: sessionTicket) }', cover)
        self.assertIn('capturedRecipe: capturedRecipe, ticket: sessionTicket)', cover)
        callback = body(cover, 'onCapture: {')
        close = body(cover, 'onClose: {')
        self.assertIn('if cameraSession?.id == sessionTicket { cameraSession = nil }', callback)
        self.assertEqual(compact(close), 'if cameraSession?.id == sessionTicket { cameraSession = nil }')
        self.assertIn('captureSlotAvailable: model.captureSlotAvailable', cover)
        self.assertIn('if model.captureSlotAvailable { Task { await model.renderIfNeeded() } }', cover)


if __name__ == '__main__':
    unittest.main(verbosity=2)
