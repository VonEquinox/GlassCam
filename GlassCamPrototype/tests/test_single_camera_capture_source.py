"""Static single-camera capture wiring contracts, NOT an Apple SDK/device test.

These checks guard the intended ownership, cancellation, retained-frame and UI
boundaries. Tokens and ordering cannot prove an AVCaptureSession works on device,
that its freeze is visible, or that Apple delivers full-size ProRAW. Hardware validation is recorded separately.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "ios/GlassCam/CameraController.swift").read_text()
FRAMES = (ROOT / "ios/GlassCam/CameraFrameDelivery.swift").read_text()
VIEW = (ROOT / "ios/GlassCam/CameraView.swift").read_text()


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class SingleCameraViewContracts(unittest.TestCase):
    def test_shutter_snapshots_before_authorization_and_camera_submission(self):
        shutter = section(VIEW, "private func shutter(", "private enum CaptureUIError")
        self.assertLess(shutter.index('let snapshot = CaptureSnapshot'), shutter.index('workflow.capture('))
        self.assertLess(shutter.index('workflow.capture('), shutter.index('camera.captureProRAW'))
        self.assertIn('!workflow.canCapture', shutter)
        self.assertIn('scenePhase == .active', shutter)

    def test_scene_stop_does_not_own_the_committed_photo(self):
        self.assertIn('if phase == .background { camera.stop() }', VIEW)
        workflow = (ROOT / 'ios/GlassCam/CaptureWorkflow.swift').read_text()
        self.assertIn('guard job?.id == id, phase == .capturing else { return }', workflow)
        self.assertNotIn('settingsPresented', workflow)
        self.assertNotIn('scenePhase', workflow)

    def test_saved_output_never_silently_retargets_to_lower_resolution(self):
        selected = section(VIEW, 'private var selectedOutput:', 'private func offerCompactPanel')
        self.assertIn('$0.megapixels == saved', selected)
        self.assertNotIn('$0.megapixels <= saved', selected)
        self.assertIn('Selected output is unavailable.', VIEW)
        self.assertNotIn('Open editor', VIEW)


class SingleCameraBackendContracts(unittest.TestCase):
    def assertOrdered(self, text, *tokens):
        previous = -1
        for token in tokens:
            index = text.find(token, previous + 1)
            self.assertGreater(index, previous, token)
            previous = index


    def test_highest_source_capability_does_not_use_multicam_or_preview_filter(self):
        capability = section(SOURCE, "private func photoCapability(", "private func validate(")
        self.assertIn("center.activeFormat", capability)
        self.assertIn("center.formats.flatMap", capability)
        self.assertIn("Self.area(largest) == sourceCeiling", capability)
        for forbidden in ("isMultiCamSupported", "previewLongEdge", "videoSupportedFrameRateRanges"):
            self.assertNotIn(forbidden, capability)
        native = section(SOURCE, "private func nativePhotoDimensions(", "private static func sameAspect(")
        self.assertIn("nominal == 12 || nominal == 48", native)
        self.assertNotIn("multi", native.lower())
        photo = section(SOURCE, "private func buildSinglePhotoGraph(", "private func photoCapability(")
        self.assertIn("let newSession = AVCaptureSession()", photo)
        self.assertIn("newSession.sessionPreset = .photo", photo)
        self.assertNotRegex(photo, r"activeFormat\s*=(?!=)")
        self.assertIn("try validate(try photoCapability(center), matches: photo)", photo)

    def test_graph_ownership_is_released_before_each_new_graph(self):
        for start, end in (("private func buildSinglePhotoGraph(", "private func photoCapability("),):
            body = section(SOURCE, start, end)
            self.assertOrdered(body, "try checkLifetime()", "guard session == nil", "let newSession =")
        teardown = section(SOURCE, "private func tearDownGraph(", "    func stop()")
        self.assertOrdered(teardown, "setSampleBufferDelegate(nil", "delivery.callbackQueue.sync {}",
                           "old.stopRunning()", "old.removeConnection", "old.removeOutput",
                           "old.removeInput", "old.commitConfiguration()", "session = nil")
        self.assertNotIn("finishRequest(", teardown)


    def test_preview_readiness_requires_real_enqueued_frame_before_freeze(self):
        freeze = section(FRAMES, "func freeze()", "func invalidate()")
        self.assertIn("active = false; generation &+= 1", freeze)
        self.assertIn("liveSource.invalidate()", freeze)
        self.assertNotIn(".flush(", freeze)
        delivery = section(FRAMES, "func captureOutput(", "func captureOutput(_ output: AVCaptureOutput, didDrop")
        self.assertOrdered(delivery, "CMSampleBufferDataIsReady", "CVPixelBufferGetPixelFormatType",
                           "CVPixelBufferGetWidth", "CVPixelBufferGetHeight", "generation == ticket",
                           "renderer.isReadyForMoreMediaData", "renderer.enqueue(sampleBuffer)", "first?()")
        teardown = section(SOURCE, "private func tearDownGraph(", "    func stop()")
        self.assertIn("if preservingPreview { delivery.freeze() } else { delivery.invalidate() }", teardown)
        self.assertIn("frozenDeliveries = frameDeliveries", teardown)

    def test_freeze_is_a_fence_against_admitted_main_enqueue_and_queued_flush(self):
        delivery = section(FRAMES, "func captureOutput(", "func captureOutput(_ output: AVCaptureOutput, didDrop")
        main = delivery.split("DispatchQueue.main.async", 1)[1]
        self.assertOrdered(main, "self.lock.lock()", "guard self.active, self.generation == ticket",
                           "let renderer", "renderer.enqueue(sampleBuffer)",
                           "self.pending = false; self.lock.unlock()", "first?()")
        self.assertNotIn("self.lock.unlock()\n            let renderer", main)
        expect = section(FRAMES, "func expect(", "func freeze()")
        self.assertOrdered(expect, "DispatchQueue.main.async", "self.lock.lock()",
                           "guard self.active, self.generation == ticket", ".flush(")

    def test_background_cancellation_is_synchronous_and_readiness_wait_is_cancelable(self):
        stop = section(SOURCE, "    func stop()", "    /// Delivers only")
        self.assertOrdered(stop, "lifetime.cancel()", "generation = UUID()", "backend.queue.async")
        lifetime = section(SOURCE, "private final class CameraLifetime", "private struct CapturedProRAW")
        self.assertIn("private let lock = NSLock()", lifetime)
        self.assertIn("lock.lock(); cancelled = true; lock.unlock()", lifetime)
        validate = section(SOURCE, "private func validateRunningGraph()", "private func waitForPreviewFrames()")
        self.assertIn("try checkLifetime()", validate)
        self.assertIn("!session.isInterrupted", validate)
        wait = section(SOURCE, "private func waitForPreviewFrames()", "private static func previewEncoding(")
        self.assertIn("previewReadiness.wait(timeout: .now() + 0.05)", wait)
        self.assertIn("DispatchTime.now() >= deadline", wait)
        self.assertGreaterEqual(wait.count("try validateRunningGraph()"), 2)

    def test_photo_readiness_guards_request_lifetime_orientation_and_ordinary_session(self):
        ready = section(SOURCE, "private func waitUntilPhotoReady(", "private func submitPhoto(")
        self.assertOrdered(ready, "guard currentRequest === request", "try request.lifetime.check()",
                           "session.sessionPreset == .photo",
                           "try validate(try photoCapability(center), matches: request.capability)",
                           "interfaceOrientation == request.orientation", "output.captureReadiness == .ready",
                           "try submitPhoto(request, output: output)")
        self.assertIn("queue.asyncAfter", ready)
        self.assertIn("DispatchTime.now() >= deadline", ready)
        submit = section(SOURCE, "private func submitPhoto(", "private func finishPhoto(")
        self.assertIn("self.currentRequest === request", submit)
        self.assertIn("settings.maxPhotoDimensions = request.capability.dimensions", submit)
        self.assertIn("settings.photoQualityPrioritization = .quality", submit)
        self.assertIn("self.phase == .capturing", submit)
        self.assertIn("Photo capture timed out", submit)
        for forbidden in ("OutputOption", "outputMegapixels", "previewLongEdge",
                          "settings.isAutoStillImageStabilizationEnabled"):
            self.assertNotIn(forbidden, submit)

    def test_orientation_is_immutable_until_terminal_completion_and_restoration(self):
        update = section(SOURCE, "func updateOrientation(", "    func stop()")
        self.assertOrdered(update, "orientation = value", "guard !isConfiguring, !isCapturing",
                           "centerLiveSource?.setEnabled(false)", "backend.queue.async")
        request = section(SOURCE, "private final class CaptureRequest", "    let queue =")
        self.assertIn("let orientation: UIInterfaceOrientation", request)
        rotate = section(SOURCE, "func rotatePreview(", "private func applyOrientation(")
        self.assertIn("guard phase == .preview, currentRequest == nil", rotate)
        controller = section(SOURCE, "func captureProRAW(", "    deinit")
        self.assertOrdered(controller, "self.isCapturing = false", "if outcome.previewReady { self.updateOrientation(self.orientation) }")

    def test_rapid_rotation_coalesces_latest_orientation_and_failed_rotation_stops_graph(self):
        update = section(SOURCE, "func updateOrientation(", "    func stop()")
        self.assertIn("!isApplyingOrientation", update)
        self.assertOrdered(update, "orientation = value", "!isApplyingOrientation",
                           "isApplyingOrientation = true", "try backend.rotatePreview(value)",
                           "self.appliedOrientation = value", "self.isApplyingOrientation = false",
                           "self.updateOrientation(self.orientation)")
        rotate = section(SOURCE, "func rotatePreview(", "private func applyOrientation(")
        self.assertIn("failSession(error.localizedDescription, stopRunning: true)", rotate)
        self.assertIn("throw error", rotate)

    def test_preview_failure_and_stale_ui_do_not_replace_committed_photo(self):
        finish = section(SOURCE, "private func finishPhoto(", "private func finishRequest(")
        self.assertOrdered(finish, "guard currentRequest === request", "request.result = result",
                           "if !request.lifetime.isCancelled && !failed && phase != .stopped",
                           "try validateRunningGraph()", "try request.lifetime.check()",
                           "finishRequest(request, result: result")
        self.assertIn("previewError = error.localizedDescription", finish)
        self.assertNotIn("result = .failure", finish)
        controller = section(SOURCE, "func captureProRAW(", "    deinit")
        self.assertIn("guard let self, self.generation == token else { completion(photoResult); return }", controller)
        self.assertIn("self.isReady = outcome.previewReady", controller)

    def test_terminal_callback_is_commit_point_and_cancel_returns_only_terminal_success(self):
        processed = section(SOURCE, "didFinishProcessingPhoto photo:", "    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor")
        self.assertIn("result = .success(CapturedProRAW", processed)
        self.assertNotIn("terminalResult =", processed)
        self.assertNotIn("callback?(", processed)
        terminal = section(SOURCE, "didFinishCaptureFor resolvedSettings:", "    @discardableResult")
        self.assertOrdered(terminal, "lock.lock()", "guard completion != nil", "error.map { .failure($0) } ?? result",
                           "completion = nil", "terminalResult = finalResult", "lock.unlock()", "callback?(finalResult)")
        cancel = SOURCE.split('func cancel(reason: String = "Camera capture cancelled.")', 1)[1]
        self.assertIn("if let terminalResult { value = terminalResult }", cancel)
        self.assertIn("else { value = .failure(CameraFailure(reason)) }", cancel)
        self.assertOrdered(cancel, "completion = nil", "result = nil", "lock.unlock()", "callback?(value)")

    def test_stop_and_failure_preserve_terminal_result_with_exactly_once_completion(self):
        stop = SOURCE.rsplit("    func stop()", 1)[1].split("private final class ProRAWCapture", 1)[0]
        self.assertOrdered(stop, "lifetime?.cancel()", "let request = currentRequest",
                           "request?.result ?? captureDelegate?.cancel()", "tearDownGraph(preservingPreview: false)",
                           "finishRequest(request, result: result")
        finish = section(SOURCE, "private func finishRequest(", "private func failSession(")
        self.assertOrdered(finish, "guard currentRequest === request, let callback = request.completion",
                           "request.completion = nil", "currentRequest = nil", "callback(CaptureOutcome(result: result")
        fail = section(SOURCE, "private func failSession(", "private func installObservers(")
        self.assertIn("request.result ?? captureDelegate?.cancel(reason: message)", fail)

    def test_returned_photo_validates_raw_type_and_metadata_and_pixel_buffer_dimensions(self):
        processed = section(SOURCE, "didFinishProcessingPhoto photo:", "    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor")
        for token in ("photo.isRawPhoto", "AVCapturePhotoOutput.isAppleProRAWPixelFormat(CVPixelBufferGetPixelFormatType(buffer))",
                      "photo.fileDataRepresentation()", "!data.isEmpty", "photo.resolvedSettings.rawPhotoDimensions",
                      "min(expectedDimensions.width, expectedDimensions.height)",
                      "max(expectedDimensions.width, expectedDimensions.height)",
                      "CVPixelBufferGetWidth(buffer)", "CVPixelBufferGetHeight(buffer)",
                      "min(bufferWidth, bufferHeight) == Int(min(actual.width, actual.height))",
                      "max(bufferWidth, bufferHeight) == Int(max(actual.width, actual.height))"):
            self.assertIn(token, processed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
