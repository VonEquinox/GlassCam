import Foundation
import OSLog

public enum PeripheralDiagnostics {
    public static let isEnabled = ProcessInfo.processInfo.environment["GLASSCAM_PERIPHERAL_TRACE"] == "1"
    public static func trace(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        Logger(subsystem: "dev.glasscam.prototype", category: "PeripheralTrace")
            .notice("\(text, privacy: .public)")
    }
}
