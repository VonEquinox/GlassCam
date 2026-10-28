import Foundation

extension ProcessingRecipe {
    func displayName(resources: ColorResources) -> String {
        if mode == .lumix { return "LUMIX · \(lumix.title)" }
        guard mode == .ffcs else { return "HNCS · \(hncs.presetTitle) · \(hncs.filmCurve.title)" }
        let actual = FFCSEngine.resolvedAssetFamily(resources: resources, simulationIndex, family: ffcs.cameraFamily)
        let family = actual.map { $0 == ffcs.cameraFamily.rawValue ? $0 : "\(ffcs.cameraFamily.rawValue) / \($0) asset" }
            ?? "\(ffcs.cameraFamily.rawValue) / asset unavailable"
        return "FFCS · \(family) · \(FFCSEngine.simulationName(at: simulationIndex))"
    }

}
