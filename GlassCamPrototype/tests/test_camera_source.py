"""Source contracts, NOT an Apple compilation or camera/device capability test."""
import unittest
from pathlib import Path

SOURCE = (Path(__file__).resolve().parents[1] / 'ios/GlassCam/CameraController.swift').read_text()
FRAMES = (Path(__file__).resolve().parents[1] / 'ios/GlassCam/CameraFrameDelivery.swift').read_text()

class CameraSourceContracts(unittest.TestCase):
    def test_single_physical_main_camera(self):
        self.assertIn('.builtInWideAngleCamera', SOURCE)
        for forbidden in ('.builtInUltraWideCamera', '.builtInTelephotoCamera',
                          'AVCaptureMultiCamSession', 'supportedMultiCamDeviceSets'):
            self.assertNotIn(forbidden, SOURCE)

    def test_graph_uses_manual_center_photo_connection(self):
        for token in ['AVCaptureSession()', 'addInputWithNoConnections', 'addOutputWithNoConnections',
                      'AVCaptureConnection(inputPorts: [port], output: output)',
                      'AVCaptureVideoDataOutput()',
                      'AVCaptureConnection(inputPorts: [port], output: video)']:
            self.assertIn(token, SOURCE)

    def test_proraw_is_verified_at_setup_request_and_delivery(self):
        self.assertGreaterEqual(SOURCE.count('output.isAppleProRAWSupported'), 3)
        self.assertIn('output.isAppleProRAWEnabled = true', SOURCE)
        self.assertIn('availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)', SOURCE)
        self.assertIn('AVCapturePhotoSettings(rawPixelFormatType: raw)', SOURCE)
        self.assertIn('CVPixelBufferGetPixelFormatType(buffer)', SOURCE)
        self.assertIn('photo.resolvedSettings.rawPhotoDimensions', SOURCE)
        self.assertNotIn('AVCapturePhotoSettings(format:', SOURCE)

    def test_no_implicit_resolution_or_framing_downgrade(self):
        for token in ['sourceCeiling', 'Self.area(largest) == sourceCeiling',
                      'center.videoZoomFactor = expected?.zoom ?? 1', 'connection.videoScaleAndCropFactor = 1',
                      'connection.preferredVideoStabilizationMode = .off',
                      'output.maxPhotoDimensions = dimensions', 'settings.maxPhotoDimensions = request.capability.dimensions',
                      'settings.photoQualityPrioritization = .quality', 'connection.videoOrientation = orientation']:
            self.assertIn(token, SOURCE)

    def test_output_targets_are_separate_from_source(self):
        for token in ['struct OutputOption', 'supportedOutputOptions', 'physicalCameraID',
                      'centerPreviewLongEdge',
                      'newSession.sessionPreset = .photo', 'nominal == 12 || nominal == 48',
                      '[24, 48].filter { $0 <= sourceTier }', 'min(divisor, Int(sqrt(',
                      'outputOptions: Self.outputOptions(source: photo.dimensions)']:
            self.assertIn(token, SOURCE)
        capture = SOURCE.split('private func submitPhoto(', 1)[1].split('private func finishPhoto(', 1)[0]
        self.assertNotIn('OutputOption', capture)
        self.assertNotIn('megapixels', capture)
        self.assertIn('settings.maxPhotoDimensions = request.capability.dimensions', capture)

    def test_bounded_capture_and_failure_observation(self):
        for token in ['currentRequest == nil', 'didFinishCaptureFor', 'runtimeErrorNotification',
                      'wasInterruptedNotification', 'interruptionEndedNotification',
                      'systemPressureState', 'level == .serious', 'captureDelegate?.cancel()']:
            self.assertIn(token, SOURCE)
        for token in ['video.alwaysDiscardsLateVideoFrames = true',
                      'video.automaticallyConfiguresOutputBufferDimensions = false',
                      'video.deliversPreviewSizedOutputBuffers = false',
                      'kCVPixelBufferWidthKey as String: width', 'kCVPixelBufferHeightKey as String: height']:
            self.assertIn(token, SOURCE)
        for token in ['guard !pending', 'pending = true', 'self.pending = false',
                      'generation == ticket', 'kCMSampleAttachmentKey_DisplayImmediately',
                      'onFirstValidFrame', 'renderer.isReadyForMoreMediaData', 'renderer.enqueue(sampleBuffer)',
                      'flush(removingDisplayedImage: true, completionHandler: nil)']:
            self.assertIn(token, FRAMES)
        self.assertNotIn('Int(max(video.width, video.height)) <= previewLongEdge', SOURCE)
        self.assertNotIn('AVCaptureVideoPreviewLayer', SOURCE)
        self.assertIn('previewReadiness.wait(timeout: .now() + 0.05)', SOURCE)
        self.assertIn('try waitForPreviewFrames()', SOURCE)

    def test_terminal_failure_finishes_pending_capture_once(self):
        failure = SOURCE.split('private func failSession(', 1)[1].split('private func installObservers', 1)[0]
        for token in ['dispatchPrecondition(condition: .onQueue(queue))', 'failed = true',
                      'captureDelegate?.cancel(reason: message)', 'failureHandler?(message)',
                      'finishPhoto(result, request: request)']:
            self.assertIn(token, failure)
        observers = SOURCE.split('private func installObservers', 1)[1].split('private func tearDownGraph', 1)[0]
        self.assertEqual(observers.count('self.failSession('), 2)
        self.assertEqual(observers.count('self.session === observed'), 2)
        self.assertIn('stopRunning: true', observers)
        finish = SOURCE.split('private func finishRequest(', 1)[1].split('private func failSession(', 1)[0]
        self.assertLess(finish.index('request.completion = nil'), finish.index('callback(CaptureOutcome('))
        self.assertIn('guard currentRequest === request', finish)
        self.assertIn('currentRequest = nil; captureDelegate = nil', finish)
        controller_capture = SOURCE.split('func captureProRAW(', 1)[1].split('deinit', 1)[0]
        self.assertIn('DispatchQueue.main.async', controller_capture)
        self.assertIn('self.isCapturing = false', controller_capture)

if __name__ == '__main__':
    unittest.main(verbosity=2)
