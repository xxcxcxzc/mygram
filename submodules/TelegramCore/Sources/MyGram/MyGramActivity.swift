import Foundation
import Postbox
internal import TelegramApi

/// One stretch of time a person was online.
public struct MyGramActivitySession {
    public let start: Int32
    /// nil while still online.
    public let end: Int32?
}

/// "Activity log": when the people I chose came online and went offline. Built from the
/// online/offline updates Telegram already sends this app, so it only covers time while the app
/// was receiving updates, and only people whose "last seen" is visible to me.
public enum MyGramActivityLog {
    private static let lock = NSLock()
    private static let maxSessions = 60

    private static func key(_ peerId: Int64) -> String {
        return "mygram.activity.\(peerId)"
    }

    private static func load(_ peerId: Int64) -> [MyGramActivitySession] {
        guard let raw = MyGramSettings.store.array(forKey: key(peerId)) as? [[NSNumber]] else {
            return []
        }
        return raw.compactMap { item in
            guard let start = item.first else {
                return nil
            }
            let end = item.count > 1 ? item[1].int32Value : nil
            return MyGramActivitySession(start: start.int32Value, end: end)
        }
    }

    private static func save(_ peerId: Int64, _ sessions: [MyGramActivitySession]) {
        let trimmed = sessions.suffix(maxSessions)
        let raw: [[NSNumber]] = trimmed.map { session in
            if let end = session.end {
                return [NSNumber(value: session.start), NSNumber(value: end)]
            }
            return [NSNumber(value: session.start)]
        }
        MyGramSettings.store.set(raw, forKey: key(peerId))
    }

    /// Newest first.
    public static func sessions(peerId: Int64) -> [MyGramActivitySession] {
        lock.lock()
        defer { lock.unlock() }
        return load(peerId).reversed()
    }

    public static func clear(peerId: Int64) {
        lock.lock()
        MyGramSettings.store.removeObject(forKey: key(peerId))
        lock.unlock()
    }

    static func recordOnline(peerId: Int64, at timestamp: Int32) {
        lock.lock()
        defer { lock.unlock() }
        var sessions = load(peerId)
        if let last = sessions.last, last.end == nil {
            return
        }
        sessions.append(MyGramActivitySession(start: timestamp, end: nil))
        save(peerId, sessions)
    }

    static func recordOffline(peerId: Int64, wasOnline: Int32) {
        lock.lock()
        defer { lock.unlock() }
        var sessions = load(peerId)
        if let last = sessions.last, last.end == nil {
            sessions[sessions.count - 1] = MyGramActivitySession(start: last.start, end: max(last.start, wasOnline))
            save(peerId, sessions)
        } else if let last = sessions.last, let lastEnd = last.end, wasOnline > lastEnd + 60 {
            // Came and went while we weren't told it was online: a short visit ending at wasOnline.
            sessions.append(MyGramActivitySession(start: wasOnline, end: wasOnline))
            save(peerId, sessions)
        } else if sessions.isEmpty {
            sessions.append(MyGramActivitySession(start: wasOnline, end: wasOnline))
            save(peerId, sessions)
        }
    }
}

/// Called for every presence update of another user.
func myGramRecordPresence(peerId: PeerId, status: Api.UserStatus) {
    guard peerId.namespace == Namespaces.Peer.CloudUser, MyGramSettings.applies(.activity, peerId: peerId.toInt64()) else {
        return
    }
    let now = Int32(Date().timeIntervalSince1970)
    switch status {
    case .userStatusOnline:
        MyGramActivityLog.recordOnline(peerId: peerId.toInt64(), at: now)
    case let .userStatusOffline(data):
        MyGramActivityLog.recordOffline(peerId: peerId.toInt64(), wasOnline: data.wasOnline)
    default:
        break
    }
}
