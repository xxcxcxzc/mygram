import Foundation
import Postbox

/// A signature added under my messages in chosen chats (usually channels), before sending.
///
/// The text uses simple markup:
///   **жирний**  __курсив__  ++підкреслений++  ~~закреслений~~  `код`  ||спойлер||
///   [текст посилання](https://адреса)
public struct MyGramSignature: Codable, Equatable {
    public var id: String
    public var text: String
    public var isEnabled: Bool
    /// Chats it is added in, as `PeerId.toInt64()` values.
    public var peers: [Int64]

    public init(id: String, text: String, isEnabled: Bool, peers: [Int64]) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
        self.peers = peers
    }
}

public extension MyGramSettings {
    private static let signaturesKey = "mygram.signatures"

    static var signatures: [MyGramSignature] {
        get {
            guard let data = MyGramSettings.store.data(forKey: signaturesKey) else {
                return []
            }
            return (try? JSONDecoder().decode([MyGramSignature].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                MyGramSettings.store.set(data, forKey: signaturesKey)
            }
            NotificationCenter.default.post(name: MyGramSettings.didChangeNotification, object: nil)
        }
    }

    static func updateSignature(_ signature: MyGramSignature) {
        var all = MyGramSettings.signatures
        if let index = all.firstIndex(where: { $0.id == signature.id }) {
            all[index] = signature
        } else {
            all.append(signature)
        }
        MyGramSettings.signatures = all
    }

    static func removeSignature(id: String) {
        MyGramSettings.signatures = MyGramSettings.signatures.filter { $0.id != id }
    }

    /// The first enabled, non-empty signature for this chat.
    static func signature(peerId: Int64) -> MyGramSignature? {
        return MyGramSettings.signatures.first(where: { $0.isEnabled && $0.peers.contains(peerId) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

/// Turns the markup into plain text and entities (ranges in UTF-16 units, as Telegram counts them).
public func myGramParseSignatureMarkup(_ source: String) -> (text: String, entities: [MessageTextEntity]) {
    let markers: [(token: String, type: MessageTextEntityType)] = [
        ("**", .Bold),
        ("__", .Italic),
        ("++", .Underline),
        ("~~", .Strikethrough),
        ("||", .Spoiler),
        ("`", .Code)
    ]
    let input = Array(source)
    var output = ""
    var outputLength = 0
    var entities: [MessageTextEntity] = []
    var openMarkers: [(token: String, start: Int)] = []

    func append(_ value: String) {
        output.append(value)
        outputLength += (value as NSString).length
    }

    func matches(_ token: String, at index: Int) -> Bool {
        let tokenChars = Array(token)
        if index + tokenChars.count > input.count {
            return false
        }
        for offset in 0 ..< tokenChars.count where input[index + offset] != tokenChars[offset] {
            return false
        }
        return true
    }

    var index = 0
    scan: while index < input.count {
        // [text](url)
        if input[index] == "[" {
            if let closeBracket = input[(index + 1)...].firstIndex(of: "]"), closeBracket + 1 < input.count, input[closeBracket + 1] == "(", let closeParen = input[(closeBracket + 2)...].firstIndex(of: ")") {
                let label = String(input[(index + 1) ..< closeBracket])
                let url = String(input[(closeBracket + 2) ..< closeParen]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty && !url.isEmpty {
                    let start = outputLength
                    append(label)
                    entities.append(MessageTextEntity(range: start ..< outputLength, type: .TextUrl(url: url)))
                    index = closeParen + 1
                    continue scan
                }
            }
        }
        for marker in markers where matches(marker.token, at: index) {
            if let openIndex = openMarkers.lastIndex(where: { $0.token == marker.token }) {
                let start = openMarkers[openIndex].start
                openMarkers.remove(at: openIndex)
                if outputLength > start {
                    entities.append(MessageTextEntity(range: start ..< outputLength, type: marker.type))
                }
            } else {
                openMarkers.append((marker.token, outputLength))
            }
            index += marker.token.count
            continue scan
        }
        append(String(input[index]))
        index += 1
    }
    return (output, entities)
}

private func myGramCanCarryCaption(_ media: Media?) -> Bool {
    guard let media = media else {
        return true
    }
    if media is TelegramMediaImage {
        return true
    }
    if let file = media as? TelegramMediaFile {
        return !file.isSticker && !file.isAnimatedSticker && !file.isInstantVideo
    }
    return false
}

/// Adds the chat's signature, after an empty line, to the messages about to be sent. In an album
/// only one message gets it (the one with text, else the first).
func myGramApplySignatures(peerId: PeerId, messages: [(Bool, EnqueueMessage)]) -> [(Bool, EnqueueMessage)] {
    guard let signature = MyGramSettings.signature(peerId: peerId.toInt64()) else {
        return messages
    }
    let parsed = myGramParseSignatureMarkup(signature.text)
    if parsed.text.isEmpty {
        return messages
    }

    // Pick which message of each album is signed.
    var signedGroupMessage: [Int64: Int] = [:]
    for (index, item) in messages.enumerated() {
        if case let .message(text, _, _, _, _, _, _, localGroupingKey, _, _) = item.1, let groupingKey = localGroupingKey {
            if signedGroupMessage[groupingKey] == nil || (!text.isEmpty && messages[signedGroupMessage[groupingKey]!].1.myGramText.isEmpty) {
                signedGroupMessage[groupingKey] = index
            }
        }
    }

    var result: [(Bool, EnqueueMessage)] = []
    for (index, item) in messages.enumerated() {
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = item.1 else {
            result.append(item)
            continue
        }
        if let groupingKey = localGroupingKey, signedGroupMessage[groupingKey] != index {
            result.append(item)
            continue
        }
        if attributes.contains(where: { $0 is RichTextMessageAttribute }) || !myGramCanCarryCaption(mediaReference?.media) {
            result.append(item)
            continue
        }
        let separator = text.isEmpty ? "" : "\n\n"
        let newText = text + separator + parsed.text
        let limit = mediaReference == nil ? 4096 : 1024
        if (newText as NSString).length > limit {
            result.append(item)
            continue
        }
        let offset = (text as NSString).length + (separator as NSString).length
        let added = parsed.entities.map { entity in
            return MessageTextEntity(range: (entity.range.lowerBound + offset) ..< (entity.range.upperBound + offset), type: entity.type)
        }
        var updatedAttributes = attributes.filter { !($0 is TextEntitiesMessageAttribute) }
        let existing = (attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        updatedAttributes.append(TextEntitiesMessageAttribute(entities: existing + added))
        result.append((item.0, .message(text: newText, attributes: updatedAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)))
    }
    return result
}

private extension EnqueueMessage {
    var myGramText: String {
        if case let .message(text, _, _, _, _, _, _, _, _, _) = self {
            return text
        }
        return ""
    }
}
