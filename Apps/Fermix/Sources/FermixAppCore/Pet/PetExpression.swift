import Foundation

public enum PetExpression: String, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking

    static func resolve(for mode: VoiceMode, callActive: Bool) -> PetExpression {
        switch mode {
        case .listening:
            return .listening
        case .muted:
            return .listening
        case .speaking:
            return .speaking
        case .thinking, .toolUse:
            return .thinking
        case .idle where callActive:
            return .listening
        case .offline, .idle, .error:
            return .idle
        }
    }

    func layerAssetName(_ layer: PetLayer) -> String {
        "pet_\(rawValue)_\(layer.rawValue)"
    }
}

enum PetLayer: String {
    case body
    case ring
    case face
    case decor
}
