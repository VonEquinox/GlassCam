"""Source contracts, NOT an Apple compilation or camera/device capability test."""
import unittest
from pathlib import Path

SOURCE = (Path(__file__).resolve().parents[1] / 'ios/GlassCam/CameraController.swift').read_text()
FRAMES = (Path(__file__).resolve().parents[1] / 'ios/GlassCam/CameraFrameDelivery.swift').read_text()

class CameraSourceContracts(unittest.TestCase):
    def test_physical_lenses_and_simultaneous_gates(self):
        for token in ['.builtInUltraWideCamera', '.builtInWideAngleCamera', '.builtInTelephotoCamera',
                      'AVCaptureMultiCamSession.isMultiCamSupported', 'supportedMultiCamDeviceSets',
                      'format.isMultiCamSupported', 'multiSession.hardwareCost', 'multiSession.systemPressureCost']:
            self.assertIn(token, SOURCE)
        self.assertNotIn('.builtInTripleCamera', SOURCE)

    def test_graph_uses_manual_center_photo_connection(self):
        for token in ['.inputPriority', 'addInputWithNoConnections', 'addOutputWithNoConnections',
                      'AVCaptureConnection(inputPorts: [ports[0]], output: output)',
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
                      'device.videoZoomFactor = 1', 'connection.videoScaleAndCropFactor = 1',
                      'connection.preferredVideoStabilizationMode = .off',
                      'output.maxPhotoDimensions = dimensions', 'settings.maxPhotoDimensions = dimensions',
                      'settings.photoQualityPrioritization = .quality', 'connection.videoOrientation = orientation']:
            self.assertIn(token, SOURCE)

    def test_output_targets_are_separate_from_source(self):
        for token in ['struct OutputOption', 'supportedOutputOptions', 'physicalCameraID',
                      'centerPreviewLongEdge', 'peripheralPreviewLongEdge',
                      'newSession.sessionPreset = .photo', 'nominal == 12 || (!multi && nominal == 48)',
                      '[12, 24, 48].filter { $0 <= sourceTier }', 'min(divisor, Int(sqrt(',
                      'outputOptions: Self.outputOptions(source: dimensions)']:
            self.assertIn(token, SOURCE)
        capture = SOURCE.split('func capture(completion:', 1)[1].split('private func installObservers', 1)[0]
        self.assertNotIn('OutputOption', capture)
        self.assertNotIn('megapixels', capture)
        self.assertIn('settings.maxPhotoDimensions = dimensions', capture)

    def test_bounded_capture_and_failure_observation(self):
        for token in ['captureDelegate == nil', 'didFinishCaptureFor', 'runtimeErrorNotification',
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
        self.assertIn('previewReadiness.wait(timeout: .now() + 5)', SOURCE)
        self.assertIn('try waitForPreviewFrames()', SOURCE)

if __name__ == '__main__':
    unittest.main(verbosity=2)
