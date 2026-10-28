import ImagingCore
import Capture
import F5
import Peripheral
import CHNCS
import CFFCS
import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MetalKit
import QuartzCore
import SwiftUI
import UIKit

enum LiveSourceValidation {
    /// Require authoritative buffer tags. Format-description tags detect conflicts;
    /// they are never a reason to silently relabel an untagged buffer as Rec.709.
    static func validate(_ frame: LiveCameraFrame) -> String? {
        let buffer = frame.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format),
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return "Live color requires tagged 8-bit NV12 video." }
        // This also rejects aperture, aspect and chroma-attachment discrepancies,
        // rather than cropping one interpretation while CI decodes another.
        guard CMVideoFormatDescriptionMatchesImageBuffer(frame.formatDescription, imageBuffer: buffer) else {
            return "Live color paused: camera format and buffer metadata disagree."
        }
        func attachment(_ key: CFString) -> CFTypeRef? {
            // Copy imports as ARC-managed CFTypeRef; no Unmanaged conversion.
            CVBufferCopyAttachment(buffer, key, nil)
        }
        func colorTag(_ key: CFString, formatKey: CFString) -> String? {
            guard let value = attachment(key) as? String else { return nil }
            if let other = CMFormatDescriptionGetExtension(frame.formatDescription, extensionKey: formatKey) as? String,
               other != value { return nil }
            return value
        }
        guard let primaries = colorTag(kCVImageBufferColorPrimariesKey, formatKey: kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = colorTag(kCVImageBufferTransferFunctionKey, formatKey: kCMFormatDescriptionExtension_TransferFunction),
              let matrix = colorTag(kCVImageBufferYCbCrMatrixKey, formatKey: kCMFormatDescriptionExtension_YCbCrMatrix) else {
            return "Live color paused: missing or conflicting camera color tags."
        }
        guard [kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
               kCVImageBufferColorPrimaries_P3_D65 as String].contains(primaries),
              [kCVImageBufferTransferFunction_ITU_R_709_2 as String,
               kCVImageBufferTransferFunction_sRGB as String].contains(transfer),
              [kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
               kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String].contains(matrix) else {
            return "Live color paused: this HDR/log or color encoding has not been validated."
        }
        // CI owns actual YCbCr/chroma conversion; retain its original attachments.
        let top = attachment(kCVImageBufferChromaLocationTopFieldKey) as? String
        let bottom = attachment(kCVImageBufferChromaLocationBottomFieldKey) as? String
        if let top, let bottom, top != bottom { return "Live color does not support interlaced chroma locations." }
        for location in [top, bottom].compactMap({ $0 }) {
            let supported = [kCVImageBufferChromaLocation_Left as String,
                             kCVImageBufferChromaLocation_Center as String,
                             kCVImageBufferChromaLocation_TopLeft as String]
            guard supported.contains(location) else { return "Live color does not support this chroma location." }
        }
        if let aspect = attachment(kCVImageBufferPixelAspectRatioKey) as? [String: Any] {
            guard let horizontal = aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber,
                  let vertical = aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber,
                  horizontal.doubleValue.isFinite, vertical.doubleValue.isFinite,
                  horizontal.doubleValue > 0, horizontal.doubleValue == vertical.doubleValue else {
                return "Live color requires square camera pixels."
            }
        }
        let raster = CGRect(x: 0, y: 0, width: CGFloat(CVPixelBufferGetWidth(buffer)),
                            height: CGFloat(CVPixelBufferGetHeight(buffer)))
        guard validAperture(frame.cleanRect, in: raster) else { return "Live color received an invalid clean aperture." }
        return nil
    }
    static func validAperture(_ aperture: CGRect, in raster: CGRect) -> Bool {
        !aperture.isEmpty && !aperture.isInfinite && !aperture.isNull && raster.contains(aperture)
    }
}
