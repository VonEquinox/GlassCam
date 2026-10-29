import Foundation
import Photos
import SwiftUI
import Testing
import UIKit
import ImagingCore
import Peripheral
@testable import GlassCam

@Suite(.serialized) @MainActor
struct PhotoDeliveryTests {
    @Test(arguments: [PHAuthorizationStatus.authorized, .limited])
    func authorization_requestsAddOnly(status: PHAuthorizationStatus) async throws {
        var levels: [PHAccessLevel] = []
        var dependencies = HEIFSaveDelivery.Dependencies.system
        dependencies.authorize = { level in levels.append(level); return status }
        try await HEIFSaveDelivery.authorizePhotos(dependencies: dependencies)
        #expect(levels == [.addOnly])
    }
    @Test(arguments: [PHAuthorizationStatus.denied, .restricted, .notDetermined])
    func permissionFailure_neverImports(status: PHAuthorizationStatus) async {
        var imports = 0
        var dependencies = HEIFSaveDelivery.Dependencies.system
        dependencies.status = { _ in status }
        dependencies.importPhoto = { _, completion in imports += 1; completion(true,nil) }
        await #expect(throws: HEIFSaveDelivery.Error.permissionDenied) {
            try await HEIFSaveDelivery.saveToPhotos(TemporaryHEIFFile(), dependencies: dependencies)
        }
        #expect(imports == 0)
    }
    @Test func photoImport_keepsOriginalHEIFBytesNameAndOwnership() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let file = TemporaryHEIFFile(captureDate: date)
        let original = Data([0,1,2,3,255]); try original.write(to: file.url)
        var imported: HEIFSaveDelivery.PhotoImport?
        var dependencies = HEIFSaveDelivery.Dependencies.system
        dependencies.status = { _ in .authorized }; dependencies.isActive = { true }
        dependencies.importPhoto = { photo, completion in imported = photo; completion(true,nil) }

        try await HEIFSaveDelivery.saveToPhotos(file, dependencies: dependencies)

        #expect(imported?.url == file.url)
        #expect(imported?.options.shouldMoveFile == false)
        #expect(try Data(contentsOf: file.url) == original)
    }
    @Test func photoImport_preservesFilenameDateAndPhotoResourceType() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let file = TemporaryHEIFFile(captureDate: date)
        var imported: HEIFSaveDelivery.PhotoImport?
        var dependencies = HEIFSaveDelivery.Dependencies.system
        dependencies.status = { _ in .limited }; dependencies.isActive = { true }
        dependencies.importPhoto = { photo, completion in imported = photo; completion(true,nil) }
        try await HEIFSaveDelivery.saveToPhotos(file, dependencies: dependencies)
        #expect(imported?.options.originalFilename == file.url.lastPathComponent)
        #expect(imported?.captureDate == date)
        #expect(imported?.type == .photo)
    }
    @Test func backgroundTransition_beforeImportRetainsFile() async throws {
        let file = TemporaryHEIFFile(captureDate: Date())
        let original = Data([5,6,7]); try original.write(to: file.url)
        var checks = 0, imports = 0
        var dependencies = HEIFSaveDelivery.Dependencies.system
        dependencies.status = { _ in .authorized }
        dependencies.isActive = { checks += 1; return checks == 1 }
        dependencies.importPhoto = { _, completion in imports += 1; completion(true,nil) }
        await #expect(throws: HEIFSaveDelivery.Error.inactive) { try await HEIFSaveDelivery.saveToPhotos(file, dependencies: dependencies) }
        #expect(imports == 0)
        #expect(try Data(contentsOf: file.url) == original)
    }
    @Test func documentPickerDuplicateCallbacks_completeOnlyOnce() throws {
        let file = TemporaryHEIFFile()
        try Data([1,2,3]).write(to: file.url)
        var results: [Bool] = []
        let coordinator = HEIFFileSaveSheet.Coordinator(file: file) { results.append($0) }
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        coordinator.documentPicker(picker, didPickDocumentsAt: [file.url])
        coordinator.documentPickerWasCancelled(picker)
        #expect(results == [true])
    }
}

struct CameraControlsTests {
    @Test(arguments: ["no-geometry","settings","review","capture","frozen"])
    func compactPanel_waitsUntilPresentationIsSafe(blocker: String) {
        var panel = CompactCameraPanel()
        let result = panel.offer(hasGeometry: blocker != "no-geometry", style: .separate,
                                 settingsPresented: blocker == "settings", reviewing: blocker == "review",
                                 capturing: blocker == "capture", frozen: blocker == "frozen")
        #expect(!result)
        #expect(!panel.offered)
    }
    @Test func compactPanel_dismissalDoesNotImmediatelyReopen() {
        var panel = CompactCameraPanel()
        let first = panel.offer(hasGeometry: true, style: .separate, settingsPresented: false, reviewing: false, capturing: false, frozen: false)
        let second = panel.offer(hasGeometry: true, style: .separate, settingsPresented: false, reviewing: false, capturing: false, frozen: false)
        #expect(first)
        #expect(!second)
    }
    @Test(arguments: [(false,false,false),(false,true,false),(true,true,false),(true,false,true)])
    func review_requiresSavedPhotoAndIdleWorkflow(hasPhoto: Bool, working: Bool, expected: Bool) {
        #expect(CameraControlsAvailability.canReview(hasPhoto: hasPhoto, working: working) == expected)
    }
    @Test(arguments: [CGSize(width: 390,height: 844),CGSize(width: 844,height: 390),CGSize(width: 200,height: 200)])
    func controls_stayWithinSafePeriphery(size: CGSize) {
        let framing = CameraFraming(size: size, photoAspectRatio: size.width > size.height ? 4.0/3.0 : 3.0/4.0)
        let layout = CameraChromeLayout(framing: framing, safeArea: EdgeInsets(top: 20,leading: 12,bottom: 20,trailing: 12), needsAccessiblePanel: false)
        let controls = [layout.first, layout.second].filter { !$0.isEmpty }
        let overlaps = controls.map { $0.intersection(framing.photo) }.filter { !$0.isNull }.filter { !$0.isEmpty }
        let outsideWindow = controls.filter { !framing.window.contains($0) }
        #expect(overlaps.isEmpty)
        #expect(outsideWindow.isEmpty)
    }
    @Test func accessibilityText_usesSeparatePanelWithoutChangingPhoto() {
        let framing = CameraFraming(size: CGSize(width: 390,height: 844), photoAspectRatio: 0.75)
        let photo = framing.photo
        let layout = CameraChromeLayout(framing: framing, safeArea: .init(), needsAccessiblePanel: true)
        #expect(layout.style == .separate)
        #expect(framing.photo == photo)
    }
    @Test func grid_usesThirdsInsidePhotoBounds() {
        let size = CGSize(width: 300,height: 600)
        let path = PhotoFrameGuide.grid(size: size)
        var points: [CGPoint] = []
        path.forEach { element in
            switch element { case .move(to: let point), .line(to: let point): points.append(point); default: break }
        }
        #expect(points == [CGPoint(x:100,y:0),CGPoint(x:100,y:600),CGPoint(x:0,y:200),CGPoint(x:300,y:200),
                           CGPoint(x:200,y:0),CGPoint(x:200,y:600),CGPoint(x:0,y:400),CGPoint(x:300,y:400)])
    }
}
