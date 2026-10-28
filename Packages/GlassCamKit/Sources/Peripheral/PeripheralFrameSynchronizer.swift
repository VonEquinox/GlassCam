import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Synchronizer owns sample delivery. Always forward a valid center frame even
/// when an auxiliary stream is absent/dropped; only the perimeter becomes black.
#if os(iOS)
public final class PeripheralFrameSynchronizer: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    public let queue = DispatchQueue(label: "dev.glasscam.preview.synchronized", qos: .userInteractive)
    public let source: PeripheralFrameSource
    public let outputs: [AVCaptureVideoDataOutput]
    public let deliveries: [any PeripheralFrameInput]
    let clockProvider: () -> CMClock?
    private var lastDiagnosticTime = -Double.infinity
    public init(source: PeripheralFrameSource, outputs: [AVCaptureVideoDataOutput], deliveries: [any PeripheralFrameInput], clock: @escaping () -> CMClock?) {
        self.source = source; self.outputs = outputs; self.deliveries = deliveries; self.clockProvider = clock
        deliveries.first?.observeSubmissions { [weak source] pts in source?.recordSubmittedCenter(pts) }
    }
    public func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        if PeripheralDiagnostics.isEnabled, CACurrentMediaTime() - lastDiagnosticTime >= 1 {
            lastDiagnosticTime = CACurrentMediaTime()
            let streams = outputs.enumerated().map { index, output -> String in
                guard let data = collection.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData else {
                    return "\(index):absent"
                }
                return "\(index):dropped=\(data.sampleBufferWasDropped) reason=\(data.droppedReason.rawValue) timestamp=\(CMTimeGetSeconds(data.timestamp)) pts=\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(data.sampleBuffer)))"
            }.joined(separator: " ")
            PeripheralDiagnostics.trace("synchronizer \(streams)")
        }
        func sample(_ index: Int) -> CMSampleBuffer? {
            guard outputs.indices.contains(index),
                  let data = collection.synchronizedData(for: outputs[index]) as? AVCaptureSynchronizedSampleBufferData,
                  !data.sampleBufferWasDropped else { return nil }
            return data.sampleBuffer
        }
        receiveSamples(sample)
    }
    func receiveSamples(_ sample: (Int) -> CMSampleBuffer?) {
        let center = sample(0)
        if let center { deliveries[0].receive(center) }
        let selection = source.selection()
        let outer = selection.outputIndex.flatMap(sample)
        source.offer(center: center, outer: outer, selection: selection, clock: clockProvider(), sameCollection: center != nil && outer != nil)
    }
}

#endif
