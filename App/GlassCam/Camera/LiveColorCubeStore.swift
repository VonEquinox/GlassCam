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

private enum LiveProxyFailure: LocalizedError {
    case unavailable(String), cancelled
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message; case .cancelled: return "Live color build superseded." }
    }
}

final class LiveColorCube {
    let recipe: LiveColorRecipe
    let rgbaFloat32Data: Data
    init(recipe: LiveColorRecipe, rgbaFloat32Data: Data) {
        self.recipe = recipe; self.rgbaFloat32Data = rgbaFloat32Data
    }
}

/// One utility worker + one replaceable requested recipe, with a two-cube LRU.
/// Cancellation is checked between 65²-node slabs, never a CPU camera-frame job.
final class LiveColorCubeStore {
    private struct Request {
        let recipe: LiveColorRecipe
        let revision: UInt64
        let completion: (Result<LiveColorCube, Error>) -> Void
    }
    private let queue: DispatchQueue
    init(queue: DispatchQueue = DispatchQueue(label: "dev.glasscam.live-color-bake", qos: .utility)) { self.queue = queue }
    private let lock = NSLock()
    private var pending: Request?
    private var running = false
    private var revision: UInt64 = 0
    private var cache: [LiveColorCube] = []
    private let cacheLimit = 2

    func request(_ recipe: LiveColorRecipe, completion: @escaping (Result<LiveColorCube, Error>) -> Void) {
        lock.lock()
        revision &+= 1
        pending = Request(recipe: recipe, revision: revision, completion: completion)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }
    func cancel(clearCache: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1; pending = nil
        if clearCache { cache.removeAll() }
    }
    private func isCurrent(_ ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return revision == ticket
    }
    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else { running = false; lock.unlock(); return }
            pending = nil
            let cachedIndex = cache.firstIndex { $0.recipe == request.recipe }
            let cached = cachedIndex.map { cache.remove(at: $0) }
            if let cached { cache.append(cached) }
            lock.unlock()
            let result: Result<LiveColorCube, Error> = Result {
                if let cached { return cached }
                return try bake(request.recipe, ticket: request.revision)
            }
            lock.lock()
            let current = revision == request.revision
            if current, cached == nil, case .success(let cube) = result {
                cache.append(cube)
                if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
            }
            lock.unlock()
            guard current else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(request.revision) else { return }
                request.completion(result)
            }
        }
    }
    private func bake(_ recipe: LiveColorRecipe, ticket: UInt64) throws -> LiveColorCube {
        if let reason = recipe.unsupportedReason { throw LiveProxyFailure.unavailable(reason) }
        let n = LiveColorRecipe.dimension, slabPixels = n * n
        var rgba = [Float](repeating: 0, count: n * n * n * 4)
        var input = [Float](repeating: 0, count: slabPixels * 3)
        var message = [CChar](repeating: 0, count: 1024)
        var ffcs: OpaquePointer?
        if recipe.mode == .ffcs {
            guard let directory = recipe.resources.ffcsDirectory else {
                throw LiveProxyFailure.unavailable("Original FFCS resources are unavailable.")
            }
            ffcs = directory.path.withCString { path in
                recipe.ffcs.cameraFamily.rawValue.withCString { family in
                    message.withUnsafeMutableBufferPointer { error in
                        ffcs_create_family_config(path, family, recipe.simulationIndex,
                            recipe.effects.applyGrain ? 1 : 0, recipe.effects.applySharpness ? 1 : 0,
                            recipe.ffcs.applyReferenceAdjustments ? 1 : 0, recipe.ffcs.sharpenRadius,
                            error.baseAddress, error.count)
                    }
                }
            }
            guard ffcs != nil else { throw LiveProxyFailure.unavailable(String(cString: message)) }
        } else {
            throw LiveProxyFailure.unavailable("This color engine uses the system viewfinder preview.")
        }
        defer {
            if let ffcs { ffcs_destroy(ffcs) }
        }
        func inverseSRGB(_ index: Int) -> Float {
            let q = Double(index) / Double(n - 1)
            return Float(q <= 0.04045 ? q / 12.92 : pow((q + 0.055) / 1.055, 2.4))
        }
        let nodes = (0..<n).map(inverseSRGB)
        for blue in 0..<n {
            guard isCurrent(ticket) else { throw LiveProxyFailure.cancelled }
            // CIColorCube layout: R varies fastest, then G, then B.
            for green in 0..<n {
                for red in 0..<n {
                    let p = (green * n + red) * 3
                    input[p] = nodes[red]; input[p + 1] = nodes[green]; input[p + 2] = nodes[blue]
                }
            }
            let success = input.withUnsafeBufferPointer { source in
                rgba.withUnsafeMutableBufferPointer { output in
                    let destination = output.baseAddress!.advanced(by: blue * slabPixels * 4)
                    return message.withUnsafeMutableBufferPointer { error in
                        ffcs_process_linear_rgb_color_only(ffcs, source.baseAddress, source.count,
                            slabPixels, destination, slabPixels * 4, error.baseAddress, error.count) == 1
                    }
                }
            }
            guard success else { throw LiveProxyFailure.unavailable("Live-color core failed: \(String(cString: message))") }
        }
        guard isCurrent(ticket) else { throw LiveProxyFailure.cancelled }
        guard rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              stride(from: 3, to: rgba.count, by: 4).allSatisfy({ rgba[$0] == 1 }) else {
            throw LiveProxyFailure.unavailable("Live-color cube violates its display-linear RGBA contract.")
        }
        return LiveColorCube(recipe: recipe, rgbaFloat32Data: rgba.withUnsafeBytes { Data($0) })
    }
}
