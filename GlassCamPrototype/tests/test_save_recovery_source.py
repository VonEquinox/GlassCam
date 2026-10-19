"""Source contracts for delivery/recovery; not UIKit/Photos runtime tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class SaveRecoveryContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.view = (ROOT/'ios/GlassCam/ContentView.swift').read_text()
        cls.save = (ROOT/'ios/GlassCam/HEIFSaveDelivery.swift').read_text()
        cls.pipeline = (ROOT/'ios/GlassCam/ImagePipeline.swift').read_text()

    def test_save_original_file_without_compatibility_encoder(self):
        self.assertIn('requestAuthorization(for: .addOnly)', self.save)
        self.assertNotIn('.readWrite', self.save)
        self.assertIn('addResource(with: .photo, fileURL: file.url', self.save)
        self.assertIn('options.shouldMoveFile = false', self.save)
        self.assertIn('completionHandler: { [file]', self.save)
        self.assertIn('forExporting: [file.url], asCopy: true', self.save)
        for prohibited in ('ShareDelivery', 'writeJPEG', 'UIImage(', 'jpegData'):
            self.assertNotIn(prohibited, self.save)
        self.assertIn('controller.excludedActivityTypes = [.saveToCameraRoll]', self.view)

    def test_save_retry_uses_encoded_file_and_keeps_single_admission(self):
        workflow = (ROOT/'ios/GlassCam/CaptureWorkflow.swift').read_text()
        self.assertIn('if let existing = current.encoded { encoded = existing }', workflow)
        self.assertIn('job?.encoded = encoded', workflow)
        self.assertIn('try await services.save(encoded.file)', workflow)
        self.assertIn('guard canCapture, snapshot.recipe.isValid else { return }', workflow)
        self.assertIn('guard phase == .failed, task == nil else { return }', workflow)
        self.assertIn('case .memory(Data)', workflow.replace('case memory(Data)', 'case .memory(Data)'))

    def test_completed_capture_does_not_navigate_to_editor(self):
        view = (ROOT/'ios/GlassCam/CameraView.swift').read_text()
        self.assertIn('workflow.capturePhoto(snapshot: snapshot)', view)
        self.assertIn('CaptureReview(capture: capture, onBack:', view)
        self.assertIn('ShareSheet(file: capture.file)', view)
        self.assertNotIn('Open editor', view)
        self.assertNotIn('PhotosPicker', self.view)

if __name__=='__main__': unittest.main()
