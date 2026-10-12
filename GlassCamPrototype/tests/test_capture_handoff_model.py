"""Executable capture-handoff specification, NOT a test of the Swift implementation.

This deterministic fake-camera model makes permitted event ordering explicit and
checks the safety invariants across short interleavings. Production wiring is
checked separately by test_capture_handoff_source.py. Neither suite validates
Apple APIs, actual camera ownership, valid DNGs, renderer freeze, or device timing.
"""
from dataclasses import dataclass, field
from itertools import product
import unittest


@dataclass
class HandoffModel:
    """A serial-queue specification with asynchronous, generation-tagged events."""
    generation: int = 1
    phase: str = "preview"
    owners: set = field(default_factory=lambda: {"preview"})
    request: tuple | None = None
    next_request: int = 0
    deliveries: dict = field(default_factory=dict)
    completed_photo: str | None = None
    processed_photo: str | None = None
    frozen_frame: int | None = None
    latest_frame: int = 7
    pending_orientation: str = "portrait"
    capture_orientation: str | None = None
    output_target: int | None = None
    native_source: int = 48
    shown_live: bool = True
    restore_feeds: set = field(default_factory=set)
    log: list = field(default_factory=list)

    def _start(self, name):
        assert not self.owners, "Two camera sessions must never own the device"
        self.owners.add(name)
        self.log.append(("start", name))

    def _stop(self):
        for owner in sorted(self.owners):
            self.log.append(("stop", owner))
        self.owners.clear()

    def _complete(self, result):
        if self.request is not None:
            self.deliveries.setdefault(self.request, []).append(result)
            self.request = None

    def shutter(self, target=12):
        if self.phase != "preview" or self.request is not None:
            return None
        self.next_request += 1
        self.request = (self.generation, self.next_request)
        self.output_target = target
        self.capture_orientation = self.pending_orientation
        self.frozen_frame = self.latest_frame
        self.shown_live = False
        self.completed_photo = None
        self.processed_photo = None
        self.phase = "frozen"
        return self.request

    def advance(self):
        if self.phase == "frozen":
            self._stop()
            self.phase = "photo_setup"
        elif self.phase == "photo_setup":
            self._start("photo")
            self.phase = "capturing"
        elif self.phase == "photo_finished":
            self._stop()
            self.phase = "restore_setup"
        elif self.phase == "restore_setup":
            self._start("preview")
            self.restore_feeds.clear()
            self.phase = "restoring"

    def did_process_photo(self, ticket):
        if ticket == self.request and self.phase == "capturing":
            self.processed_photo = "DNG"

    def did_finish_capture(self, ticket, success=True):
        # didFinishProcessingPhoto alone does not commit the DNG.
        if ticket != self.request or self.phase != "capturing":
            return
        self.completed_photo = (self.processed_photo or "capture_error") if success else "capture_error"
        self.phase = "photo_finished"

    def restore_frame(self, ticket, feed):
        if ticket != self.request or self.phase != "restoring":
            return
        self.restore_feeds.add(feed)
        if self.restore_feeds == {"center", "peripheral"}:
            self.phase = "preview"
            self.shown_live = True
            self.frozen_frame = None
            self._complete(self.completed_photo)

    def restore_failure(self, ticket):
        if ticket != self.request or self.phase not in {"restore_setup", "restoring"}:
            return
        self._stop()
        self.phase = "failed"
        # A camera-restart failure cannot discard a completed photo.
        self._complete(self.completed_photo)

    def rotate(self, orientation="landscape"):
        self.pending_orientation = orientation
        # The current request keeps its shutter orientation and export snapshot.

    def stop(self):
        self.generation += 1
        self._stop()
        # Preserve only terminal-success DNG; an intermediate processed sample
        # may still be followed by a capture-transaction error.
        self._complete(self.completed_photo if self.completed_photo == "DNG" else "cancelled")
        self.phase = "stopped"
        self.shown_live = False
        self.frozen_frame = None

    def restart(self):
        # Models a user retry/lens change only after the active request is over.
        if self.request is not None:
            return
        self.generation += 1
        self._stop()
        self._start("preview")
        self.phase = "preview"
        self.shown_live = True
        self.frozen_frame = None

    def invariant(self):
        assert len(self.owners) <= 1
        assert all(len(results) == 1 for results in self.deliveries.values())
        if self.shown_live:
            assert self.phase == "preview" and self.owners == {"preview"}
        if self.phase in {"frozen", "photo_setup", "capturing", "photo_finished",
                          "restore_setup", "restoring"}:
            assert self.request is not None and not self.shown_live
            assert self.frozen_frame is not None
        if self.phase == "capturing":
            assert self.owners == {"photo"}


class CaptureHandoffModelTests(unittest.TestCase):
    def capture_finished(self):
        m = HandoffModel()
        ticket = m.shutter()
        m.advance(); m.advance()
        m.did_process_photo(ticket)
        m.did_finish_capture(ticket)
        return m, ticket

    def test_single_owner_at_every_handoff_boundary(self):
        m, ticket = self.capture_finished()
        m.advance(); m.advance()
        m.restore_frame(ticket, "center")
        self.assertFalse(m.shown_live)
        m.restore_frame(ticket, "peripheral")
        self.assertEqual(m.log, [("stop", "preview"), ("start", "photo"),
                                 ("stop", "photo"), ("start", "preview")])
        self.assertEqual(m.deliveries[ticket], ["DNG"])
        m.invariant()

    def test_shutter_freezes_an_actual_frame_and_snapshots_output_and_rotation(self):
        m = HandoffModel()
        ticket = m.shutter(target=24)
        self.assertEqual(m.frozen_frame, 7)
        m.latest_frame = 8
        m.rotate()
        self.assertEqual(m.frozen_frame, 7)
        self.assertEqual(m.capture_orientation, "portrait")
        self.assertEqual(m.pending_orientation, "landscape")
        self.assertEqual(m.output_target, 24)
        self.assertEqual(m.native_source, 48)
        self.assertIsNone(m.shutter(target=48))
        m.restart()
        self.assertEqual(m.request, ticket)
        m.invariant()

    def test_success_is_not_lost_if_preview_restoration_fails(self):
        for start_preview in (False, True):
            m, ticket = self.capture_finished()
            m.advance()
            if start_preview:
                m.advance()
            m.restore_failure(ticket)
            self.assertEqual(m.deliveries[ticket], ["DNG"])
            self.assertEqual(m.phase, "failed")
            self.assertFalse(m.shown_live)
            m.did_finish_capture(ticket)
            m.restore_failure(ticket)
            self.assertEqual(m.deliveries[ticket], ["DNG"])
            m.invariant()

    def test_stop_at_every_boundary_rejects_late_callbacks_and_restoration(self):
        for boundary in range(7):
            m = HandoffModel()
            ticket = m.shutter()
            operations = [m.advance, m.advance, lambda: m.did_process_photo(ticket),
                          lambda: m.did_finish_capture(ticket), m.advance, m.advance]
            for operation in operations[:boundary]:
                operation()
            m.stop()
            for operation in operations:
                operation()
            m.restore_frame(ticket, "center")
            m.restore_frame(ticket, "peripheral")
            m.restore_failure(ticket)
            expected = "DNG" if boundary >= 4 else "cancelled"
            self.assertEqual(m.deliveries[ticket], [expected])
            self.assertEqual(m.phase, "stopped")
            self.assertFalse(m.owners)
            m.invariant()

    def test_processing_success_does_not_mask_later_terminal_error(self):
        m = HandoffModel(); ticket = m.shutter()
        m.advance(); m.advance(); m.did_process_photo(ticket)
        self.assertNotIn(ticket, m.deliveries)
        m.did_finish_capture(ticket, success=False)
        m.advance(); m.restore_failure(ticket)
        self.assertEqual(m.deliveries[ticket], ["capture_error"])
        m.invariant()

    def test_duplicate_terminal_error_cannot_replace_first_committed_success(self):
        m, ticket = self.capture_finished()
        m.did_finish_capture(ticket, success=False)
        self.assertEqual(m.completed_photo, "DNG")
        m.stop()
        m.did_finish_capture(ticket, success=False)
        self.assertEqual(m.deliveries[ticket], ["DNG"])
        m.invariant()

    def test_old_callbacks_cannot_finish_or_release_new_request(self):
        m = HandoffModel()
        old = m.shutter()
        m.stop(); m.restart()
        current = m.shutter()
        m.advance(); m.advance()
        m.did_finish_capture(old)
        m.restore_failure(old)
        m.restore_frame(old, "center")
        self.assertEqual(m.request, current)
        self.assertEqual(m.phase, "capturing")
        self.assertEqual(m.owners, {"photo"})
        self.assertNotIn(current, m.deliveries)
        m.invariant()

    def test_capture_error_still_restores_preview_and_completes_once(self):
        m = HandoffModel(); ticket = m.shutter()
        m.advance(); m.advance(); m.did_finish_capture(ticket, success=False)
        m.advance(); m.advance()
        m.restore_frame(ticket, "peripheral"); m.restore_frame(ticket, "center")
        self.assertEqual(m.deliveries[ticket], ["capture_error"])
        self.assertTrue(m.shown_live)
        m.did_finish_capture(ticket)
        m.invariant()

    def test_short_event_interleavings_preserve_safety_invariants(self):
        # 100,000 deterministic sequences include repeated shutters, late terminal
        # callbacks, cancellation, rotation, and partial/duplicate restore frames.
        events = ("advance", "finish", "stop", "shutter", "rotate", "center",
                  "peripheral", "restore_failure", "process", "restart")
        for sequence in product(events, repeat=5):
            m = HandoffModel(); ticket = m.shutter()
            for event in sequence:
                if event == "process":
                    m.did_process_photo(ticket)
                elif event == "finish":
                    m.did_finish_capture(ticket)
                elif event in {"center", "peripheral"}:
                    m.restore_frame(ticket, event)
                elif event == "restore_failure":
                    m.restore_failure(ticket)
                else:
                    getattr(m, event)()
                m.invariant()


if __name__ == "__main__":
    unittest.main(verbosity=2)
