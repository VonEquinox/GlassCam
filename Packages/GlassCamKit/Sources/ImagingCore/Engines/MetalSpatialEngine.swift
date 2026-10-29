import CMetalImage
import Foundation
import os

/// Resource lookup and ownership only; scheduling and pixel operations are native.
final class MetalSpatialEngine: @unchecked Sendable {
    static let shared = MetalSpatialEngine()
    let context: OpaquePointer?
    let initializationError: String

    private init() {
        var error = [CChar](repeating: 0, count: 4096)
        let path = Bundle.module.url(forResource: "NativeSharpness", withExtension: "metal", subdirectory: "Metal")?.path ?? ""
        context = path.withCString { gc_metal_spatial_create($0, &error, error.count) }
        initializationError = String(cString: error)
        if context == nil {
            Logger(subsystem: "dev.glasscam", category: "MetalSpatial")
                .error("Metal initialization failed: \(self.initializationError, privacy: .public)")
        }
    }
    deinit { gc_metal_spatial_destroy(context) }
}
