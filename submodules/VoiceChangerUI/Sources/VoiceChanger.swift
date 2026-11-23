import Foundation
import VoiceChangerCore

/// The voice effects offered in the menu. Raw values match `VCEffect` in VoiceChangerCore
/// and are persisted, so never reorder them.
public enum VoiceChangerEffect: Int32, CaseIterable {
    case none = 0
    case chipmunk = 1
    case deep = 2
    case robot = 3
    case female = 4
    case male = 5
    case alien = 6
    case echo = 7
    case radio = 8
    case monster = 9
    case child = 10
    case cave = 11

    public var emoji: String {
        switch self {
        case .none: return "🎭"
        case .chipmunk: return "🐿"
        case .deep: return "🗿"
        case .robot: return "🤖"
        case .female: return "👩"
        case .male: return "👨"
        case .alien: return "👽"
        case .echo: return "🏔"
        case .radio: return "📻"
        case .monster: return "👹"
        case .child: return "🧒"
        case .cave: return "🦇"
        }
    }

    public var title: String {
        switch self {
        case .none: return "Мій голос"
        case .chipmunk: return "Бурундук"
        case .deep: return "Низький"
        case .robot: return "Робот"
        case .female: return "Жіночий"
        case .male: return "Чоловічий"
        case .alien: return "Прибулець"
        case .echo: return "Луна"
        case .radio: return "Рація"
        case .monster: return "Монстр"
        case .child: return "Дитина"
        case .cave: return "Печера"
        }
    }
}

/// Holds the selected voice and hands it to the audio code (voice messages, round videos, calls).
public final class VoiceChanger {
    public static let shared = VoiceChanger()

    private static let effectKey = "voiceChanger.effect"

    public private(set) var effect: VoiceChangerEffect
    private var observers: [Int: (VoiceChangerEffect) -> Void] = [:]
    private var nextObserverId = 0

    private init() {
        let stored = Int32(UserDefaults.standard.integer(forKey: VoiceChanger.effectKey))
        self.effect = VoiceChangerEffect(rawValue: stored) ?? .none
        VCSetCurrentEffect(self.effect.rawValue)
    }

    public func setEffect(_ effect: VoiceChangerEffect) {
        self.effect = effect
        VCSetCurrentEffect(effect.rawValue)
        UserDefaults.standard.set(Int(effect.rawValue), forKey: VoiceChanger.effectKey)
        for observer in self.observers.values {
            observer(effect)
        }
    }

    /// Must be called on the main thread. Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ f: @escaping (VoiceChangerEffect) -> Void) -> Int {
        let id = self.nextObserverId
        self.nextObserverId += 1
        self.observers[id] = f
        return id
    }

    public func removeObserver(_ id: Int) {
        self.observers.removeValue(forKey: id)
    }
}
