import Foundation
import Postbox
import SwiftSignalKit

/// What a message of mine is, for the auto-delete rule.
public enum MyGramMessageKind: String, CaseIterable {
    case text
    case photo
    case video
    case voice
    case round
    case sticker
    case gif
    case file
    case other

    public var title: String {
        switch self {
        case .text: return "Текст"
        case .photo: return "Фото"
        case .video: return "Відео"
        case .voice: return "Голосові"
        case .round: return "Кружечки"
        case .sticker: return "Стікери"
        case .gif: return "GIF"
        case .file: return "Файли"
        case .other: return "Інше (опитування, геопозиція…)"
        }
    }

    public var emoji: String {
        switch self {
        case .text: return "💬"
        case .photo: return "🖼"
        case .video: return "🎬"
        case .voice: return "🎤"
        case .round: return "⭕️"
        case .sticker: return "🙂"
        case .gif: return "🎞"
        case .file: return "📎"
        case .other: return "📊"
        }
    }

    static func of(media: [Media]) -> MyGramMessageKind {
        for item in media {
            if item is TelegramMediaImage {
                return .photo
            }
            if let file = item as? TelegramMediaFile {
                if file.isVoice {
                    return .voice
                }
                if file.isInstantVideo {
                    return .round
                }
                if file.isSticker || file.isAnimatedSticker {
                    return .sticker
                }
                if file.isAnimated {
                    return .gif
                }
                if file.isVideo {
                    return .video
                }
                return .file
            }
            if item is TelegramMediaWebpage {
                continue
            }
            return .other
        }
        return .text
    }
}

/// Auto-delete of my own messages. Off by default.
public extension MyGramSettings {
    private static let autoDeleteEnabledKey = "mygram.autoDelete.enabled"
    private static let autoDeleteDelayKey = "mygram.autoDelete.delay"
    private static let autoDeleteKindsKey = "mygram.autoDelete.kinds"
    private static let autoDeleteForEveryoneKey = "mygram.autoDelete.forEveryone"

    private static func notifyChanged() {
        NotificationCenter.default.post(name: MyGramSettings.didChangeNotification, object: nil)
    }

    static var autoDeleteEnabled: Bool {
        get { return UserDefaults.standard.bool(forKey: autoDeleteEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDeleteEnabledKey); notifyChanged() }
    }

    /// Seconds after sending.
    static var autoDeleteDelay: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: autoDeleteDelayKey)
            return value > 0 ? value : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: autoDeleteDelayKey); notifyChanged() }
    }

    static var autoDeleteKinds: Set<MyGramMessageKind> {
        get {
            guard let values = UserDefaults.standard.array(forKey: autoDeleteKindsKey) as? [String] else {
                return Set(MyGramMessageKind.allCases)
            }
            return Set(values.compactMap(MyGramMessageKind.init(rawValue:)))
        }
        set { UserDefaults.standard.set(newValue.map { $0.rawValue }, forKey: autoDeleteKindsKey); notifyChanged() }
    }

    /// Delete for both sides (true) or only for me (false).
    static var autoDeleteForEveryone: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoDeleteForEveryoneKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoDeleteForEveryoneKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoDeleteForEveryoneKey); notifyChanged() }
    }
}

/// Messages waiting to be deleted: account, message id, due time. Kept across restarts.
private final class MyGramAutoDeleteQueue {
    static let shared = MyGramAutoDeleteQueue()

    private static let key = "mygram.autoDelete.pending"
    private let lock = NSLock()

    struct Entry {
        let accountPeerId: Int64
        let peerId: Int64
        let namespace: Int32
        let id: Int32
        let deleteAt: Int32
        let forEveryone: Bool
    }

    private func load() -> [Entry] {
        guard let raw = UserDefaults.standard.array(forKey: MyGramAutoDeleteQueue.key) as? [[String: NSNumber]] else {
            return []
        }
        return raw.compactMap { item in
            guard let a = item["a"], let p = item["p"], let n = item["n"], let i = item["i"], let t = item["t"] else {
                return nil
            }
            return Entry(accountPeerId: a.int64Value, peerId: p.int64Value, namespace: n.int32Value, id: i.int32Value, deleteAt: t.int32Value, forEveryone: (item["e"]?.boolValue ?? true))
        }
    }

    private func save(_ entries: [Entry]) {
        let raw: [[String: NSNumber]] = entries.map { entry in
            return [
                "a": NSNumber(value: entry.accountPeerId),
                "p": NSNumber(value: entry.peerId),
                "n": NSNumber(value: entry.namespace),
                "i": NSNumber(value: entry.id),
                "t": NSNumber(value: entry.deleteAt),
                "e": NSNumber(value: entry.forEveryone)
            ]
        }
        UserDefaults.standard.set(raw, forKey: MyGramAutoDeleteQueue.key)
    }

    func add(_ entry: Entry) {
        self.lock.lock()
        var entries = self.load()
        if !entries.contains(where: { $0.accountPeerId == entry.accountPeerId && $0.peerId == entry.peerId && $0.namespace == entry.namespace && $0.id == entry.id }) {
            entries.append(entry)
            self.save(entries)
        }
        self.lock.unlock()
    }

    /// Removes and returns this account's entries that are due.
    func takeDue(accountPeerId: Int64, now: Int32) -> [Entry] {
        self.lock.lock()
        let entries = self.load()
        var due: [Entry] = []
        var rest: [Entry] = []
        for entry in entries {
            if entry.accountPeerId == accountPeerId && entry.deleteAt <= now {
                due.append(entry)
            } else {
                rest.append(entry)
            }
        }
        if !due.isEmpty {
            self.save(rest)
        }
        self.lock.unlock()
        return due
    }
}

/// Called when a message I sent got its server id: queue it if a rule matches.
func myGramScheduleAutoDelete(accountPeerId: PeerId, messageId: MessageId, media: [Media]) {
    guard MyGramSettings.autoDeleteEnabled, messageId.namespace == Namespaces.Message.Cloud else {
        return
    }
    guard MyGramSettings.applies(.autoDelete, peerId: messageId.peerId.toInt64()) else {
        return
    }
    let kind = MyGramMessageKind.of(media: media)
    guard MyGramSettings.autoDeleteKinds.contains(kind) else {
        return
    }
    let now = Int32(Date().timeIntervalSince1970)
    MyGramAutoDeleteQueue.shared.add(MyGramAutoDeleteQueue.Entry(
        accountPeerId: accountPeerId.toInt64(),
        peerId: messageId.peerId.toInt64(),
        namespace: messageId.namespace,
        id: messageId.id,
        deleteAt: now + Int32(clamping: MyGramSettings.autoDeleteDelay),
        forEveryone: MyGramSettings.autoDeleteForEveryone
    ))
}

/// Runs while the account is alive in the main app: deletes queued messages when they are due.
func myGramManagedAutoDelete(account: Account) -> Signal<Void, NoError> {
    return Signal { _ in
        let queue = Queue()
        let accountPeerId = account.peerId.toInt64()
        let deletions = DisposableSet()
        let timer = SwiftSignalKit.Timer(timeout: 5.0, repeat: true, completion: { [weak account] in
            guard let account = account else {
                return
            }
            let now = Int32(Date().timeIntervalSince1970)
            let due = MyGramAutoDeleteQueue.shared.takeDue(accountPeerId: accountPeerId, now: now)
            if due.isEmpty {
                return
            }
            for forEveryone in [true, false] {
                let ids = due.filter { $0.forEveryone == forEveryone }.map { entry in
                    return MessageId(peerId: PeerId(entry.peerId), namespace: entry.namespace, id: entry.id)
                }
                if ids.isEmpty {
                    continue
                }
                deletions.add(_internal_deleteMessagesInteractively(account: account, messageIds: ids, type: forEveryone ? .forEveryone : .forLocalPeer).start())
            }
        }, queue: queue)
        timer.start()
        return ActionDisposable {
            timer.invalidate()
            deletions.dispose()
        }
    }
}
