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

    def test_export_cancellation_crosses_queue_and_blocks_new_work(self):
        self.assertIn('exportCancellation?.cancel()', self.view)
        self.assertIn('exportWork?.cancel()', self.view)
        self.assertIn('isCancelled: { cancellation.isCancelled }', self.view)
        cancellation = self.view.split('func cancelExport()',1)[1].split('private func deliver',1)[0]
        self.assertNotIn('busy = false', cancellation)
        self.assertIn('private var cancelled = false', self.pipeline)
        self.assertIn('if isCancelled() { throw CancellationError() }', self.pipeline)
        self.assertGreaterEqual(self.pipeline.count('checkExportCancellation(isCancelled)'), 4)

    def test_failed_effect_keeps_source_and_pauses_delivery(self):
        load = self.view.split('private func beginImport',1)[1].split('func cancelImageOperation',1)[0]
        self.assertLess(load.index('imported = input'), load.index('let rendering = Task.detached'))
        self.assertIn('processed = nil', load)
        self.assertIn('processed?.recipe != recipe', self.view)
        self.assertIn('guard let processed, canDeliver else', self.view)
        self.assertIn('Button("Retry effect")', self.view)
        self.assertIn('await model.renderIfNeeded()', self.view)
        self.assertIn('guard operationID == id, !work.isCancelled', self.view)

    def test_file_cancel_and_photos_completion_are_distinct(self):
        self.assertIn('documentPickerWasCancelled', self.save)
        self.assertIn('finish(false)', self.save)
        self.assertIn('if saved { model.notice', self.view)
        submit = self.view.split('case .photos:',1)[1]
        self.assertIn('try await HEIFSaveDelivery.saveToPhotos(file)', submit)
        self.assertIn('No save was submitted.', self.view)

if __name__ == '__main__': unittest.main()
