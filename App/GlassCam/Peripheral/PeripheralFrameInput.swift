import CoreMedia

/// Receives the original synchronized sample for the center preview. The
/// observer reports submission PTS, not the time the frame appears on screen.
protocol PeripheralFrameInput: AnyObject {
    func receive(_ sampleBuffer: CMSampleBuffer)
    func observeSubmissions(_ observer: @escaping (Double) -> Void)
}
