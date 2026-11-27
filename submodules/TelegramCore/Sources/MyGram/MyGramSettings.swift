import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

/// MyGram's own switches (the 🛡 admin panel). Stored in UserDefaults, read from any thread.
public final class MyGramSettings {
    public static let didChangeNotification = Notification.Name("MyGramSettingsDidChange")

    /// Shared with the app extensions (the notification service applies deletions too), so the
    /// settings live in the app group. Values saved by older builds in the app's own defaults are
    /// copied over once.
    public static let store: UserDefaults = {
        var bundleId = Bundle.main.bundleIdentifier ?? ""
        for suffix in [".Share", ".NotificationContent", ".NotificationService", ".Widget", ".SiriIntents", ".BroadcastUpload"] where bundleId.hasSuffix(suffix) {
            bundleId = String(bundleId.dropLast(suffix.count))
        }
        guard !bundleId.isEmpty, let shared = UserDefaults(suiteName: "group." + bundleId) else {
            return UserDefaults.standard
        }
        if !shared.bool(forKey: "mygram.migratedToGroup") {
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("mygram.") {
                shared.set(value, forKey: key)
            }
            shared.set(true, forKey: "mygram.migratedToGroup")
        }
        return shared
    }()

    private static let showDeletedKey = "mygram.showDeletedMessages"
    private static let ghostHideOnlineKey = "mygram.ghost.hideOnline"
    private static let ghostOfflineAfterSendKey = "mygram.ghost.offlineAfterSend"
    private static let ghostHideTypingKey = "mygram.ghost.hideTyping"
    private static let ghostNoReadReceiptsKey = "mygram.ghost.noReadReceipts"

    private static let registerDefaults: Void = {
        MyGramSettings.store.register(defaults: [
            MyGramSettings.showDeletedKey: true,
            MyGramSettings.ghostHideOnlineKey: true,
            MyGramSettings.ghostOfflineAfterSendKey: true,
            MyGramSettings.ghostHideTypingKey: true,
            MyGramSettings.ghostNoReadReceiptsKey: true
        ])
    }()

    private static func readFlag(_ key: String) -> Bool {
        let _ = MyGramSettings.registerDefaults
        return MyGramSettings.store.bool(forKey: key)
    }

    private static func writeFlag(_ key: String, _ value: Bool) {
        let _ = MyGramSettings.registerDefaults
        MyGramSettings.store.set(value, forKey: key)
        NotificationCenter.default.post(name: MyGramSettings.didChangeNotification, object: nil)
    }

    /// Messages deleted by others stay in the chat with a "deleted" mark instead of disappearing.
    public static var showDeletedMessages: Bool {
        get { return readFlag(showDeletedKey) }
        set { writeFlag(showDeletedKey, newValue) }
    }

    /// Never tell the server we are online, so nobody sees "online" or a fresh "last seen".
    public static var ghostHideOnline: Bool {
        get { return readFlag(ghostHideOnlineKey) }
        set { writeFlag(ghostHideOnlineKey, newValue) }
    }

    /// Right after sending a message, tell the server we are offline again.
    public static var ghostOfflineAfterSend: Bool {
        get { return readFlag(ghostOfflineAfterSendKey) }
        set { writeFlag(ghostOfflineAfterSendKey, newValue) }
    }

    /// Don't send "typing…" / "recording…".
    public static var ghostHideTyping: Bool {
        get { return readFlag(ghostHideTypingKey) }
        set { writeFlag(ghostHideTypingKey, newValue) }
    }

    /// Don't send read receipts while just reading; the chat is marked read only when I reply in it.
    public static var ghostNoReadReceipts: Bool {
        get { return readFlag(ghostNoReadReceiptsKey) }
        set { writeFlag(ghostNoReadReceiptsKey, newValue) }
    }
}

/// Features that can be limited to some chats.
public enum MyGramFeature: String, CaseIterable {
    case deleted
    case typing
    case reads
    case autoDelete
    case activity
}

/// Who a feature works for.
public enum MyGramListMode: Int {
    case everyone = 0
    case everyoneExcept = 1
    case onlyThese = 2
}

public extension MyGramSettings {
    static func listMode(_ feature: MyGramFeature) -> MyGramListMode {
        let key = "mygram.list.\(feature.rawValue).mode"
        if MyGramSettings.store.object(forKey: key) == nil, feature == .activity {
            // The activity log follows nobody until people are chosen.
            return .onlyThese
        }
        return MyGramListMode(rawValue: MyGramSettings.store.integer(forKey: key)) ?? .everyone
    }

    static func setListMode(_ feature: MyGramFeature, _ mode: MyGramListMode) {
        MyGramSettings.store.set(mode.rawValue, forKey: "mygram.list.\(feature.rawValue).mode")
        NotificationCenter.default.post(name: MyGramSettings.didChangeNotification, object: nil)
    }

    /// Chats in the list, as `PeerId.toInt64()` values.
    static func listPeers(_ feature: MyGramFeature) -> Set<Int64> {
        let values = MyGramSettings.store.array(forKey: "mygram.list.\(feature.rawValue).peers") as? [NSNumber] ?? []
        return Set(values.map { $0.int64Value })
    }

    static func setListPeers(_ feature: MyGramFeature, _ peers: Set<Int64>) {
        MyGramSettings.store.set(peers.map { NSNumber(value: $0) }, forKey: "mygram.list.\(feature.rawValue).peers")
        NotificationCenter.default.post(name: MyGramSettings.didChangeNotification, object: nil)
    }

    /// Whether the feature works in the chat with this peer.
    static func applies(_ feature: MyGramFeature, peerId: Int64) -> Bool {
        switch MyGramSettings.listMode(feature) {
        case .everyone:
            return true
        case .everyoneExcept:
            return !MyGramSettings.listPeers(feature).contains(peerId)
        case .onlyThese:
            return MyGramSettings.listPeers(feature).contains(peerId)
        }
    }
}

/// Marks a message that the server deleted while "show deleted messages" was on.
public final class MyGramDeletedMessageAttribute: MessageAttribute {
    public let date: Int32

    public init(date: Int32) {
        self.date = date
    }

    required public init(decoder: PostboxDecoder) {
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.date, forKey: "d")
    }
}

public extension Message {
    var isMyGramDeleted: Bool {
        return self.attributes.contains(where: { $0 is MyGramDeletedMessageAttribute })
    }
}

public extension EngineMessage {
    var isMyGramDeleted: Bool {
        return self.attributes.contains(where: { $0 is MyGramDeletedMessageAttribute })
    }
}

/// Only regular cloud messages are kept; scheduled, quick-reply and local ones are deleted as usual.
func myGramShouldKeepDeletedMessage(_ id: MessageId) -> Bool {
    return id.namespace == Namespaces.Message.Cloud
}

/// Marks the given messages as deleted instead of removing them. Returns the ids that were kept.
func myGramMarkMessagesDeleted(transaction: Transaction, ids: [MessageId]) -> Set<MessageId> {
    var kept = Set<MessageId>()
    let timestamp = Int32(Date().timeIntervalSince1970)
    for id in ids {
        guard myGramShouldKeepDeletedMessage(id), MyGramSettings.applies(.deleted, peerId: id.peerId.toInt64()), transaction.getMessage(id) != nil else {
            continue
        }
        kept.insert(id)
        transaction.updateMessage(id, update: { currentMessage in
            if currentMessage.attributes.contains(where: { $0 is MyGramDeletedMessageAttribute }) {
                return .skip
            }
            var attributes = currentMessage.attributes
            attributes.append(MyGramDeletedMessageAttribute(date: timestamp))
            return .update(StoreMessage(updating: currentMessage, attributes: attributes, tags: currentMessage.tags))
        })
    }
    return kept
}

/// Ghost mode: after a message is sent, report "offline" so the send doesn't show us online.
func myGramReportOfflineAfterSend(network: Network) {
    guard MyGramSettings.ghostHideOnline, MyGramSettings.ghostOfflineAfterSend else {
        return
    }
    for seconds in [0.3, 1.5, 4.0, 10.0, 25.0] {
        Queue.concurrentDefaultQueue().after(seconds, {
            let _ = (network.request(Api.functions.account.updateStatus(offline: .boolTrue))
            |> `catch` { _ -> Signal<Api.Bool, NoError> in
                return .single(.boolFalse)
            }).start()
        })
    }
}

func myGramHideReadReceipts(peerId: PeerId) -> Bool {
    return MyGramSettings.ghostNoReadReceipts && MyGramSettings.applies(.reads, peerId: peerId.toInt64())
}

/// "Read only after my reply": when a message is sent while read receipts are held back, mark
/// everything in that chat as read on the server.
func myGramMarkReadAfterReply(network: Network, stateManager: AccountStateManager, peer: Peer?) {
    guard let peer = peer, myGramHideReadReceipts(peerId: peer.id) else {
        return
    }
    if peer.id.namespace == Namespaces.Peer.CloudChannel {
        guard let inputChannel = apiInputChannel(peer) else {
            return
        }
        let _ = (network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: Int32.max - 1))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }).start()
    } else if peer.id.namespace == Namespaces.Peer.CloudUser || peer.id.namespace == Namespaces.Peer.CloudGroup {
        guard let inputPeer = apiInputPeer(peer) else {
            return
        }
        let _ = (network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: Int32.max - 1))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.AffectedMessages?, NoError> in
            return .single(nil)
        }).start(next: { result in
            if let result = result {
                switch result {
                case let .affectedMessages(affectedMessagesData):
                    stateManager.addUpdateGroups([.updatePts(pts: affectedMessagesData.pts, ptsCount: affectedMessagesData.ptsCount)])
                }
            }
        })
    }
}

/// Deletion that reached the notification service as a push: keeps the messages the rules keep
/// (marked deleted) and returns the ones to delete for real.
public func myGramFilterRemoteDeletion(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    guard MyGramSettings.showDeletedMessages else {
        return ids
    }
    let kept = myGramMarkMessagesDeleted(transaction: transaction, ids: ids)
    return ids.filter { !kept.contains($0) }
}
