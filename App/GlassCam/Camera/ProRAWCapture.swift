import ImagingCore
import Capture
import F5
import Peripheral
import AVFoundation
import Combine
import OSLog
import UIKit
import ImageIO

/// Exactly one committed DNG per request. Processing bytes are provisional until
/// didFinishCaptureFor succeeds. A stop preserves that terminal result, including
/// when its backend-queue callback has not run yet; late callbacks cannot restore.
final class ProRAWCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private static let logger = Logger(subsystem: "dev.glasscam.prototype", category: "Capture")
    private let lock = NSLock()
    private var completion: ((Result<CapturedProRAW, Error>) -> Void)?
    private var result: Result<CapturedProRAW, Error>?
    private var terminalResult: Result<CapturedProRAW, Error>?
    private let expectedDimensions: CMVideoDimensions
    private let framingProvider: () -> CaptureFraming
    private var framing = CaptureFraming()
    init(expectedDimensions: CMVideoDimensions, framing: @escaping () -> CaptureFraming,
         completion: @escaping (Result<CapturedProRAW, Error>) -> Void) {
        self.expectedDimensions = expectedDimensions; self.completion = completion; self.framingProvider = framing
        self.framing = framing()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        lock.lock(); defer { lock.unlock() }
        framing = framingProvider()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        receivePhoto(isRaw: photo.isRawPhoto, buffer: photo.pixelBuffer,
                     data: { photo.fileDataRepresentation() }, actual: photo.resolvedSettings.rawPhotoDimensions,
                     metadata: photo.metadata, error: error)
    }
    func receivePhoto(isRaw: Bool, buffer: CVPixelBuffer?, data: () -> Data?, actual: CMVideoDimensions,
                      metadata: [String: Any], error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard completion != nil else { return }
        if let error { result = .failure(error); return }
        guard isRaw, let buffer,
              AVCapturePhotoOutput.isAppleProRAWPixelFormat(CVPixelBufferGetPixelFormatType(buffer)),
              let data = data(), !data.isEmpty else {
            result = .failure(CameraFailure("The camera did not return an Apple ProRAW DNG.")); return
        }
        let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        func number(_ key: CFString) -> Double? {
            guard let value = (exif?[key as String] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return value
        }
        framing.exifDigitalZoom = number(kCGImagePropertyExifDigitalZoomRatio)
        framing.exifFocalLength = number(kCGImagePropertyExifFocalLength)
        framing.exifEquivalentFocalLength = number(kCGImagePropertyExifFocalLenIn35mmFilm)
        framing.exifLensModel = exif?[kCGImagePropertyExifLensModel as String] as? String
        Self.logger.notice("ProRAW dimensions: requested=\(self.expectedDimensions.width)x\(self.expectedDimensions.height), resolved=\(actual.width)x\(actual.height), buffer=\(bufferWidth)x\(bufferHeight)")
        guard framing.acceptsRAWDimensions(requestedWidth: Int(expectedDimensions.width), requestedHeight: Int(expectedDimensions.height),
            deliveredWidth: Int(actual.width), deliveredHeight: Int(actual.height), bufferWidth: bufferWidth, bufferHeight: bufferHeight) else {
            result = .failure(CameraFailure("The camera did not deliver a valid full-framing RAW for this focal length. Wait for it to settle and try again.")); return
        }
        framing.deliveredWidth = Int(actual.width); framing.deliveredHeight = Int(actual.height)
        Self.logger.notice("Capture zoom=\(self.framing.displayZoom), lens=\(self.framing.lensName ?? "unknown", privacy: .public), RAW=\(actual.width)x\(actual.height)")
        result = .success(CapturedProRAW(data: data, dimensions: CGSize(width: CGFloat(actual.width), height: CGFloat(actual.height)), framing: framing))
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finishCapture(error: error)
    }
    func finishCapture(error: Error?) {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        let finalResult: Result<CapturedProRAW, Error> = error.map { .failure($0) } ?? result ?? .failure(CameraFailure("No Apple ProRAW photo was delivered."))
        let callback = completion; completion = nil; terminalResult = finalResult; result = nil
        lock.unlock()
        callback?(finalResult)
    }
    @discardableResult
    func cancel(reason: String = "Camera capture cancelled.") -> Result<CapturedProRAW, Error> {
        lock.lock()
        let value: Result<CapturedProRAW, Error>
        if let terminalResult { value = terminalResult }
        else { value = .failure(CameraFailure(reason)) }
        let callback = completion; completion = nil; result = nil
        lock.unlock()
        callback?(value)
        return value
    }
}
