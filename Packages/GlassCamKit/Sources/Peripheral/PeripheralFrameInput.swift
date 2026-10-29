import ImagingCore
import CoreMedia

/// Receives the original synchronized sample for the center preview.
public protocol PeripheralFrameInput: AnyObject {
    func receive(_ sampleBuffer: CMSampleBuffer)
}
