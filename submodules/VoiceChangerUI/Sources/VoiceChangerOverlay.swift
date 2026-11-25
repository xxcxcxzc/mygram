import Foundation
import UIKit
import TelegramCore

/// A window above the app that only catches touches on the floating buttons, or anywhere while a
/// panel is open. It deliberately has no root view controller, so it never takes over the status
/// bar or the interface orientation of the main window. Because of that it cannot present system
/// menus or alerts (UIMenu silently does nothing here), so the panels are plain views.
private final class VoiceChangerPassthroughWindow: UIWindow {
    var buttons: [UIView] = []
    weak var panelContainer: UIView?
    var layoutUpdated: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let panelContainer = self.panelContainer, !panelContainer.isHidden {
            return super.hitTest(point, with: event)
        }
        for button in self.buttons.reversed() {
            guard !button.isHidden, button.alpha > 0.01 else {
                continue
            }
            let local = self.convert(point, to: button)
            if button.bounds.insetBy(dx: -6.0, dy: -6.0).contains(local) {
                return button
            }
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutUpdated?()
    }
}

/// Palette for the panels, tuned for a modern dark glass look.
private enum VCPalette {
    static let accent = UIColor(red: 0.45, green: 0.32, blue: 0.96, alpha: 1.0)
    static let green = UIColor(red: 0.20, green: 0.78, blue: 0.52, alpha: 1.0)
    static let separator = UIColor(white: 1.0, alpha: 0.08)
    static let primaryText = UIColor.white
    static let secondaryText = UIColor(white: 1.0, alpha: 0.55)
    static let disabledText = UIColor(white: 1.0, alpha: 0.3)
}

/// One row of a panel.
private enum PanelRow {
    case action(icon: String, iconColor: UIColor, title: String, selected: Bool, handler: () -> Void)
    case toggle(icon: String, iconColor: UIColor, title: String, subtitle: String?, isOn: Bool, isEnabled: Bool, handler: (Bool) -> Void)
    case navigation(icon: String, title: String, value: String, handler: () -> Void)
    case segments(items: [String], selected: Int, handler: (Int) -> Void)
    case check(title: String, checked: Bool, isEnabled: Bool, handler: (Bool) -> Void)
    case note(String)
    case sectionGap
}

private final class RowActionTarget: NSObject {
    let action: () -> Void
    let toggle: ((Bool) -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
        self.toggle = nil
    }

    init(toggle: @escaping (Bool) -> Void) {
        self.action = {}
        self.toggle = toggle
    }

    @objc func performAction() {
        self.action()
    }

    @objc func switchChanged(_ sender: UISwitch) {
        self.toggle?(sender.isOn)
    }

    var segment: ((Int) -> Void)?

    @objc func segmentChanged(_ sender: UISegmentedControl) {
        self.segment?(sender.selectedSegmentIndex)
    }

    var checked: Bool = false
    weak var checkView: UIView?

    @objc func checkTapped() {
        self.checked = !self.checked
        self.checkView?.isHidden = !self.checked
        self.toggle?(self.checked)
    }
}

/// The floating buttons: 🎭 chooses a voice, 🛡 opens MyGram's settings. Tap opens a panel, drag
/// moves the button. They stay on top of every screen, including chats, recording and calls.
public final class VoiceChangerOverlay: NSObject {
    public static let shared = VoiceChangerOverlay()

    private enum ButtonKind {
        case voice
        case admin

        var positionPrefix: String {
            switch self {
            case .voice: return "voiceChanger.button"
            case .admin: return "mygram.adminButton"
            }
        }

        var defaultYFraction: CGFloat {
            switch self {
            case .voice: return 0.38
            case .admin: return 0.52
            }
        }
    }

    private static let compactKey = "voiceChanger.compactButton"

    private var window: VoiceChangerPassthroughWindow?
    private var voiceButton: UIButton?
    private var adminButton: UIButton?
    private var panelContainer: UIView?
    private var panelTargets: [RowActionTarget] = []
    private var isCompact: Bool = UserDefaults.standard.bool(forKey: VoiceChangerOverlay.compactKey)
    private var panStartCenter: CGPoint = CGPoint()

    /// Set by the app: loads the user's chats (id as `PeerId.toInt64()`, title) for the lists.
    public var loadPeers: ((@escaping ([(id: Int64, title: String)]) -> Void) -> Void)?

    private override init() {
        super.init()
    }

    /// Call once the main window is visible.
    public func install(windowScene: UIWindowScene) {
        if self.window != nil {
            return
        }

        let window = VoiceChangerPassthroughWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1.0)
        window.backgroundColor = .clear
        window.isOpaque = false
        self.window = window

        let voiceButton = self.makeFloatingButton(accessibilityLabel: "Зміна голосу", action: #selector(self.voiceButtonTapped), pan: #selector(self.handleVoicePan(_:)))
        let adminButton = self.makeFloatingButton(accessibilityLabel: "Налаштування MyGram", action: #selector(self.adminButtonTapped), pan: #selector(self.handleAdminPan(_:)))
        window.addSubview(voiceButton)
        window.addSubview(adminButton)
        window.buttons = [voiceButton, adminButton]
        self.voiceButton = voiceButton
        self.adminButton = adminButton

        window.layoutUpdated = { [weak self] in
            guard let self = self else {
                return
            }
            self.clampButtonsIntoView()
            if let panelContainer = self.panelContainer, let window = self.window {
                panelContainer.frame = window.bounds
            }
        }

        self.applyAppearance()
        self.restorePosition(.voice)
        self.restorePosition(.admin)
        window.isHidden = false

        VoiceChanger.shared.addObserver { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private func makeFloatingButton(accessibilityLabel: String, action: Selector, pan: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.layer.masksToBounds = false
        button.layer.borderWidth = 1.0
        button.layer.borderColor = UIColor(white: 1.0, alpha: 0.28).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 8.0
        button.layer.shadowOffset = CGSize(width: 0.0, height: 3.0)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.addTarget(self, action: #selector(self.buttonTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(self.buttonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: pan))
        return button
    }

    @objc private func buttonTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: 0.12) {
            sender.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
    }

    @objc private func buttonTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: 0.2, delay: 0.0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.0, options: [], animations: {
            sender.transform = .identity
        })
    }

    private var buttonSize: CGFloat {
        return self.isCompact ? 36.0 : 54.0
    }

    private func button(_ kind: ButtonKind) -> UIButton? {
        switch kind {
        case .voice: return self.voiceButton
        case .admin: return self.adminButton
        }
    }

    private func applyAppearance() {
        let size = self.buttonSize
        let effect = VoiceChanger.shared.effect
        for kind in [ButtonKind.voice, ButtonKind.admin] {
            guard let button = self.button(kind) else {
                continue
            }
            let center = button.frame.isEmpty ? nil : button.center
            button.bounds = CGRect(x: 0.0, y: 0.0, width: size, height: size)
            if let center = center {
                button.center = center
            }
            button.layer.cornerRadius = size / 2.0
            button.titleLabel?.font = UIFont.systemFont(ofSize: self.isCompact ? 18.0 : 27.0)
            let isActive: Bool
            switch kind {
            case .voice:
                button.setTitle(effect.emoji, for: .normal)
                isActive = effect != .none
            case .admin:
                button.setTitle("🛡", for: .normal)
                isActive = MyGramSettings.ghostHideOnline || MyGramSettings.showDeletedMessages
            }
            if isActive {
                button.backgroundColor = kind == .voice ? VCPalette.accent.withAlphaComponent(0.92) : VCPalette.green.withAlphaComponent(0.92)
            } else {
                button.backgroundColor = UIColor(white: 0.1, alpha: self.isCompact ? 0.5 : 0.82)
            }
            button.alpha = self.isCompact && !isActive ? 0.55 : 1.0
        }
        self.clampButtonsIntoView()
    }

    // MARK: - Panels

    @objc private func voiceButtonTapped() {
        if self.panelContainer != nil {
            self.hidePanel()
            return
        }
        self.showVoicePanel()
    }

    @objc private func adminButtonTapped() {
        if self.panelContainer != nil {
            self.hidePanel()
            return
        }
        self.showAdminPanel()
    }

    private func showVoicePanel() {
        let current = VoiceChanger.shared.effect
        var rows: [PanelRow] = []
        for effect in VoiceChangerEffect.allCases {
            rows.append(.action(icon: effect.emoji, iconColor: effect == current ? VCPalette.accent : UIColor(white: 1.0, alpha: 0.12), title: effect.title, selected: effect == current, handler: { [weak self] in
                VoiceChanger.shared.setEffect(effect)
                self?.hidePanel()
            }))
        }
        rows.append(.sectionGap)
        rows.append(.action(icon: self.isCompact ? "⤢" : "⤡", iconColor: UIColor(white: 1.0, alpha: 0.12), title: self.isCompact ? "Збільшити кнопки" : "Зменшити кнопки", selected: false, handler: { [weak self] in
            guard let self = self else {
                return
            }
            self.isCompact = !self.isCompact
            UserDefaults.standard.set(self.isCompact, forKey: VoiceChangerOverlay.compactKey)
            self.applyAppearance()
            self.hidePanel()
        }))
        self.showPanel(emoji: "🎭", title: "Зміна голосу", subtitle: "Діє в дзвінках, голосових і кружечках", rows: rows, anchor: .voice)
    }

    private func showAdminPanel(animated: Bool = true) {
        let ghost = MyGramSettings.ghostHideOnline
        var rows: [PanelRow] = [
            .toggle(icon: "🗑", iconColor: UIColor(red: 0.95, green: 0.45, blue: 0.4, alpha: 1.0), title: "Видалені повідомлення", subtitle: "Не зникають з чату, а позначаються «видалено»", isOn: MyGramSettings.showDeletedMessages, isEnabled: true, handler: { [weak self] value in
                MyGramSettings.showDeletedMessages = value
                self?.applyAppearance()
            }),
            self.listRow(.deleted),
            .sectionGap,
            .toggle(icon: "👻", iconColor: VCPalette.accent, title: "Режим привида", subtitle: "Ніхто не бачить, що ти в мережі, і час «був(ла)» не оновлюється", isOn: ghost, isEnabled: true, handler: { [weak self] value in
                MyGramSettings.ghostHideOnline = value
                self?.applyAppearance()
                DispatchQueue.main.async {
                    self?.reloadAdminPanel()
                }
            }),
            .toggle(icon: "⌨️", iconColor: UIColor(white: 1.0, alpha: 0.14), title: "Ховати «друкує…»", subtitle: nil, isOn: MyGramSettings.ghostHideTyping, isEnabled: ghost, handler: { value in
                MyGramSettings.ghostHideTyping = value
            }),
            self.listRow(.typing),
            .toggle(icon: "🚪", iconColor: UIColor(white: 1.0, alpha: 0.14), title: "«Не в мережі» після відправки", subtitle: "Одразу після повідомлення знову ставить «не в мережі»", isOn: MyGramSettings.ghostOfflineAfterSend, isEnabled: ghost, handler: { value in
                MyGramSettings.ghostOfflineAfterSend = value
            }),
            .toggle(icon: "✓", iconColor: UIColor(white: 1.0, alpha: 0.14), title: "Прочитано лише після відповіді", subtitle: "Співрозмовник побачить «прочитано» тільки коли ти відповіси в цьому чаті", isOn: MyGramSettings.ghostNoReadReceipts, isEnabled: true, handler: { value in
                MyGramSettings.ghostNoReadReceipts = value
            }),
            self.listRow(.reads),
            .note("Статус «в мережі» Telegram зберігає один для всіх, тому його не можна сховати лише від частини людей. Для цього є винятки у вбудованих налаштуваннях приватності Telegram."),
            .sectionGap,
            .toggle(icon: "🧹", iconColor: UIColor(red: 0.95, green: 0.65, blue: 0.25, alpha: 1.0), title: "Автовидалення моїх повідомлень", subtitle: "Видаляє твої повідомлення через заданий час", isOn: MyGramSettings.autoDeleteEnabled, isEnabled: true, handler: { [weak self] value in
                MyGramSettings.autoDeleteEnabled = value
                DispatchQueue.main.async {
                    self?.reloadAdminPanel()
                }
            })
        ]
        if MyGramSettings.autoDeleteEnabled {
            rows.append(.navigation(icon: "⏱", title: "Через скільки", value: VoiceChangerOverlay.delayTitle(MyGramSettings.autoDeleteDelay), handler: { [weak self] in
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showDelayPanel() }
                }
            }))
            rows.append(.navigation(icon: "🗂", title: "Що видаляти", value: self.kindsSummary(), handler: { [weak self] in
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showKindsPanel() }
                }
            }))
            rows.append(self.listRow(.autoDelete))
            rows.append(.toggle(icon: "👥", iconColor: UIColor(white: 1.0, alpha: 0.14), title: "Видаляти в обох", subtitle: "Вимкнено: зникне лише в тебе", isOn: MyGramSettings.autoDeleteForEveryone, isEnabled: true, handler: { value in
                MyGramSettings.autoDeleteForEveryone = value
            }))
        }
        rows.append(.sectionGap)
        rows.append(.navigation(icon: "📈", title: "Журнал активності", value: "Відкрити", handler: { [weak self] in
            self?.openActivity()
        }))
        self.showPanel(emoji: "🛡", title: "MyGram", subtitle: "Додаткові можливості", rows: rows, anchor: .admin, animated: animated)
    }

    private static let delayOptions: [Int] = [10, 30, 60, 300, 900, 3600, 6 * 3600, 86400, 7 * 86400]

    private static func delayTitle(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds) с"
        case ..<3600: return "\(seconds / 60) хв"
        case ..<86400: return "\(seconds / 3600) год"
        case ..<(7 * 86400): return "\(seconds / 86400) д"
        default: return "\(seconds / (7 * 86400)) тиж"
        }
    }

    private func kindsSummary() -> String {
        let kinds = MyGramSettings.autoDeleteKinds
        if kinds.count == MyGramMessageKind.allCases.count {
            return "Усе"
        }
        if kinds.isEmpty {
            return "Нічого"
        }
        return "\(kinds.count) з \(MyGramMessageKind.allCases.count)"
    }

    private func showDelayPanel() {
        let current = MyGramSettings.autoDeleteDelay
        var rows: [PanelRow] = [
            .action(icon: "‹", iconColor: UIColor(white: 1.0, alpha: 0.12), title: "Назад", selected: false, handler: { [weak self] in
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showAdminPanel(animated: false) }
                }
            }),
            .note("Повідомлення видаляється через цей час після відправки. Працює, поки MyGram запущений; що не встигло, видалиться при наступному запуску.")
        ]
        for seconds in VoiceChangerOverlay.delayOptions {
            rows.append(.action(icon: "⏱", iconColor: seconds == current ? VCPalette.accent : UIColor(white: 1.0, alpha: 0.12), title: VoiceChangerOverlay.delayTitle(seconds), selected: seconds == current, handler: { [weak self] in
                MyGramSettings.autoDeleteDelay = seconds
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showAdminPanel(animated: false) }
                }
            }))
        }
        self.showPanel(emoji: "⏱", title: "Через скільки", subtitle: "Автовидалення", rows: rows, anchor: .admin, animated: false)
    }

    private func showKindsPanel() {
        let kinds = MyGramSettings.autoDeleteKinds
        var rows: [PanelRow] = [
            .action(icon: "‹", iconColor: UIColor(white: 1.0, alpha: 0.12), title: "Назад", selected: false, handler: { [weak self] in
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showAdminPanel(animated: false) }
                }
            }),
            .note("Познач, які твої повідомлення видаляти.")
        ]
        for kind in MyGramMessageKind.allCases {
            rows.append(.check(title: "\(kind.emoji)  \(kind.title)", checked: kinds.contains(kind), isEnabled: true, handler: { value in
                var current = MyGramSettings.autoDeleteKinds
                if value {
                    current.insert(kind)
                } else {
                    current.remove(kind)
                }
                MyGramSettings.autoDeleteKinds = current
            }))
        }
        self.showPanel(emoji: "🗂", title: "Що видаляти", subtitle: "Автовидалення", rows: rows, anchor: .admin, animated: false)
    }

    private func openActivity() {
        guard let loadPeers = self.loadPeers else {
            DispatchQueue.main.async {
                self.replacePanel { $0.showActivityPanel(peers: []) }
            }
            return
        }
        loadPeers({ [weak self] peers in
            DispatchQueue.main.async {
                self?.replacePanel { $0.showActivityPanel(peers: peers) }
            }
        })
    }

    private static let activityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()

    private static let activityTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func describe(_ session: MyGramActivitySession) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(session.start))
        let startText = VoiceChangerOverlay.activityDateFormatter.string(from: start)
        guard let end = session.end else {
            return "🟢 \(startText) – зараз в мережі"
        }
        let minutes = max(0, Int(end - session.start) / 60)
        let endText = VoiceChangerOverlay.activityTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(end)))
        if end == session.start {
            return "⚪️ \(startText) – заходив(ла) ненадовго"
        }
        return "⚪️ \(startText) – \(endText) (\(minutes) хв)"
    }

    private func showActivityPanel(peers: [(id: Int64, title: String)]) {
        let mode = MyGramSettings.listMode(.activity)
        let chosen = MyGramSettings.listPeers(.activity)
        var rows: [PanelRow] = [
            .action(icon: "‹", iconColor: UIColor(white: 1.0, alpha: 0.12), title: "Назад", selected: false, handler: { [weak self] in
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showAdminPanel(animated: false) }
                }
            }),
            .navigation(icon: "👥", title: "Кого відстежувати", value: self.listSummary(.activity), handler: { [weak self] in
                self?.openList(.activity, back: { $0.openActivity() })
            }),
            .note("Записує, коли вибрані люди заходять у мережу і виходять. Telegram не повідомляє, з ким людина переписується чи говорить, тому цього не видно ніде. Журнал працює лише для тих, у кого тобі видно «був(ла)», і лише поки MyGram отримує оновлення.")
        ]
        var tracked: [(id: Int64, title: String)] = []
        for peer in peers {
            let follows: Bool
            switch mode {
            case .everyone: follows = true
            case .everyoneExcept: follows = !chosen.contains(peer.id)
            case .onlyThese: follows = chosen.contains(peer.id)
            }
            if follows && (mode == .onlyThese || !MyGramActivityLog.sessions(peerId: peer.id).isEmpty) {
                tracked.append(peer)
            }
        }
        if tracked.isEmpty {
            rows.append(.note("Поки нікого. Натисни «Кого відстежувати» і вибери людей."))
        }
        for peer in tracked.prefix(40) {
            rows.append(.sectionGap)
            let sessions = MyGramActivityLog.sessions(peerId: peer.id)
            var text = "👤 \(peer.title)"
            if sessions.isEmpty {
                text += "\nЩе немає записів"
            } else {
                for session in sessions.prefix(12) {
                    text += "\n" + VoiceChangerOverlay.describe(session)
                }
            }
            rows.append(.note(text))
        }
        self.showPanel(emoji: "📈", title: "Журнал активності", subtitle: "Коли люди були в мережі", rows: rows, anchor: .admin, animated: false)
    }

    private func featureTitle(_ feature: MyGramFeature) -> String {
        switch feature {
        case .deleted: return "Видалені повідомлення"
        case .typing: return "Ховати «друкує…»"
        case .reads: return "Прочитано лише після відповіді"
        case .autoDelete: return "Автовидалення"
        case .activity: return "Журнал активності"
        }
    }

    private func listSummary(_ feature: MyGramFeature) -> String {
        let count = MyGramSettings.listPeers(feature).count
        switch MyGramSettings.listMode(feature) {
        case .everyone: return "Усі"
        case .everyoneExcept: return "Усі, крім \(count)"
        case .onlyThese: return "Лише \(count)"
        }
    }

    private func listRow(_ feature: MyGramFeature) -> PanelRow {
        return .navigation(icon: "👥", title: "Для кого", value: self.listSummary(feature), handler: { [weak self] in
            self?.openList(feature)
        })
    }

    private func openList(_ feature: MyGramFeature, back: ((VoiceChangerOverlay) -> Void)? = nil) {
        let back = back ?? { $0.showAdminPanel(animated: false) }
        guard let loadPeers = self.loadPeers else {
            self.replacePanel { $0.showListPanel(feature, peers: [], back: back) }
            return
        }
        loadPeers({ [weak self] peers in
            DispatchQueue.main.async {
                self?.replacePanel { $0.showListPanel(feature, peers: peers, back: back) }
            }
        })
    }

    /// Swaps the open panel for another one without the fade-out.
    private func replacePanel(_ show: (VoiceChangerOverlay) -> Void) {
        if let container = self.panelContainer {
            container.removeFromSuperview()
            self.panelContainer = nil
            self.window?.panelContainer = nil
        }
        show(self)
    }

    private func showListPanel(_ feature: MyGramFeature, peers: [(id: Int64, title: String)], back: @escaping (VoiceChangerOverlay) -> Void) {
        let mode = MyGramSettings.listMode(feature)
        let selected = MyGramSettings.listPeers(feature)
        var rows: [PanelRow] = [
            .action(icon: "‹", iconColor: UIColor(white: 1.0, alpha: 0.12), title: "Назад", selected: false, handler: { [weak self] in
                DispatchQueue.main.async {
                    self?.replacePanel(back)
                }
            }),
            .segments(items: ["Усі", "Усі, крім", "Лише"], selected: mode.rawValue, handler: { [weak self] index in
                MyGramSettings.setListMode(feature, MyGramListMode(rawValue: index) ?? .everyone)
                DispatchQueue.main.async {
                    self?.replacePanel { $0.showListPanel(feature, peers: peers, back: back) }
                }
            })
        ]
        switch mode {
        case .everyone:
            rows.append(.note("Працює в усіх чатах. Вибери «Усі, крім» або «Лише», щоб позначити людей."))
        case .everyoneExcept:
            rows.append(.note("Познач чати, де функція НЕ працюватиме."))
        case .onlyThese:
            rows.append(.note("Познач чати, де функція працюватиме."))
        }
        if peers.isEmpty {
            rows.append(.note("Чати ще не завантажились. Відкрий список ще раз за хвилинку."))
        }
        let ordered = peers.filter { selected.contains($0.id) } + peers.filter { !selected.contains($0.id) }
        for peer in ordered {
            let peerId = peer.id
            rows.append(.check(title: peer.title, checked: selected.contains(peerId), isEnabled: mode != .everyone, handler: { value in
                var current = MyGramSettings.listPeers(feature)
                if value {
                    current.insert(peerId)
                } else {
                    current.remove(peerId)
                }
                MyGramSettings.setListPeers(feature, current)
            }))
        }
        self.showPanel(emoji: "👥", title: self.featureTitle(feature), subtitle: "Для кого працює", rows: rows, anchor: .admin, animated: false)
    }

    private func reloadAdminPanel() {
        guard let container = self.panelContainer else {
            return
        }
        container.removeFromSuperview()
        self.panelContainer = nil
        self.window?.panelContainer = nil
        self.panelTargets.removeAll()
        self.showAdminPanel(animated: false)
    }

    private func showPanel(emoji: String, title: String, subtitle: String, rows: [PanelRow], anchor: ButtonKind, animated: Bool = true) {
        guard let window = self.window, let button = self.button(anchor) else {
            return
        }
        self.panelTargets.removeAll()

        let container = UIView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .clear

        // The dimming view is a sibling below the card, so its tap recognizer never sees (and
        // never cancels) taps on the rows. It must render something: a fully clear view
        // receives no real touches.
        let dim = UIView(frame: container.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor(white: 0.0, alpha: 0.28)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.backgroundTapped)))
        container.addSubview(dim)

        let cardWidth: CGFloat = min(anchor == .admin ? 332.0 : 288.0, window.bounds.width - 28.0)

        // A dark glass card.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        blur.layer.cornerRadius = 22.0
        blur.layer.cornerCurve = .continuous
        blur.layer.masksToBounds = true
        blur.layer.borderWidth = 1.0
        blur.layer.borderColor = UIColor(white: 1.0, alpha: 0.1).cgColor
        let content = blur.contentView

        // Shadow holder (blur can't both clip and cast a shadow).
        let card = UIView()
        card.layer.cornerRadius = 22.0
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.4
        card.layer.shadowRadius = 24.0
        card.layer.shadowOffset = CGSize(width: 0.0, height: 10.0)
        card.addSubview(blur)
        container.addSubview(card)

        // Header: emoji chip + title + subtitle.
        let headerHeight: CGFloat = 64.0
        let chip = UILabel(frame: CGRect(x: 16.0, y: 14.0, width: 36.0, height: 36.0))
        chip.text = emoji
        chip.font = UIFont.systemFont(ofSize: 22.0)
        chip.textAlignment = .center
        chip.backgroundColor = (anchor == .admin ? VCPalette.green : VCPalette.accent).withAlphaComponent(0.22)
        chip.layer.cornerRadius = 10.0
        chip.layer.cornerCurve = .continuous
        chip.layer.masksToBounds = true
        content.addSubview(chip)

        let titleLabel = UILabel(frame: CGRect(x: 62.0, y: 15.0, width: cardWidth - 74.0, height: 20.0))
        titleLabel.text = title
        titleLabel.textColor = VCPalette.primaryText
        titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        content.addSubview(titleLabel)

        let subtitleLabel = UILabel(frame: CGRect(x: 62.0, y: 35.0, width: cardWidth - 74.0, height: 16.0))
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = VCPalette.secondaryText
        subtitleLabel.font = UIFont.systemFont(ofSize: 12.5)
        content.addSubview(subtitleLabel)

        let headerSeparator = UIView(frame: CGRect(x: 0.0, y: headerHeight, width: cardWidth, height: 1.0))
        headerSeparator.backgroundColor = VCPalette.separator
        content.addSubview(headerSeparator)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        content.addSubview(scroll)

        var y: CGFloat = 8.0
        var index = 0
        for row in rows {
            switch row {
            case let .action(icon, iconColor, title, selected, handler):
                let rowHeight: CGFloat = 50.0
                let target = RowActionTarget(action: handler)
                self.panelTargets.append(target)
                let view = self.makeActionRow(icon: icon, iconColor: iconColor, title: title, selected: selected, width: cardWidth, height: rowHeight)
                view.addTarget(target, action: #selector(RowActionTarget.performAction), for: .touchUpInside)
                view.frame = CGRect(x: 0.0, y: y, width: cardWidth, height: rowHeight)
                scroll.addSubview(view)
                y += rowHeight
                index += 1
            case let .toggle(icon, iconColor, title, subtitle, isOn, isEnabled, handler):
                let target = RowActionTarget(toggle: handler)
                self.panelTargets.append(target)
                let view = self.makeToggleRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle, isOn: isOn, isEnabled: isEnabled, width: cardWidth, target: target)
                view.frame.origin.y = y
                scroll.addSubview(view)
                y += view.frame.height
                index += 1
            case let .navigation(icon, title, value, handler):
                let rowHeight: CGFloat = 44.0
                let target = RowActionTarget(action: handler)
                self.panelTargets.append(target)
                let view = self.makeNavigationRow(icon: icon, title: title, value: value, width: cardWidth, height: rowHeight)
                view.addTarget(target, action: #selector(RowActionTarget.performAction), for: .touchUpInside)
                view.frame = CGRect(x: 0.0, y: y, width: cardWidth, height: rowHeight)
                scroll.addSubview(view)
                y += rowHeight
            case let .segments(items, selectedIndex, handler):
                let target = RowActionTarget(action: {})
                target.segment = handler
                self.panelTargets.append(target)
                let control = UISegmentedControl(items: items)
                control.selectedSegmentIndex = selectedIndex
                control.selectedSegmentTintColor = VCPalette.green
                control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
                control.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold)], for: .selected)
                control.addTarget(target, action: #selector(RowActionTarget.segmentChanged(_:)), for: .valueChanged)
                control.frame = CGRect(x: 14.0, y: y + 6.0, width: cardWidth - 28.0, height: 32.0)
                scroll.addSubview(control)
                y += 44.0
            case let .check(title, checked, isEnabled, handler):
                let rowHeight: CGFloat = 44.0
                let target = RowActionTarget(toggle: handler)
                target.checked = checked
                self.panelTargets.append(target)
                let view = self.makeCheckRow(title: title, checked: checked, isEnabled: isEnabled, width: cardWidth, height: rowHeight, target: target)
                view.frame = CGRect(x: 0.0, y: y, width: cardWidth, height: rowHeight)
                scroll.addSubview(view)
                y += rowHeight
            case let .note(text):
                let label = UILabel()
                label.numberOfLines = 0
                label.text = text
                label.textColor = VCPalette.secondaryText
                label.font = UIFont.systemFont(ofSize: 12.0)
                let size = label.sizeThatFits(CGSize(width: cardWidth - 32.0, height: .greatestFiniteMagnitude))
                label.frame = CGRect(x: 16.0, y: y + 6.0, width: cardWidth - 32.0, height: size.height)
                scroll.addSubview(label)
                y += size.height + 12.0
            case .sectionGap:
                let separator = UIView(frame: CGRect(x: 16.0, y: y + 5.0, width: cardWidth - 32.0, height: 1.0))
                separator.backgroundColor = VCPalette.separator
                scroll.addSubview(separator)
                y += 11.0
            }
        }
        y += 8.0
        scroll.contentSize = CGSize(width: cardWidth, height: y)

        let insets = window.safeAreaInsets
        let maxCardHeight = window.bounds.height - insets.top - insets.bottom - 24.0
        let cardHeight = min(headerHeight + y, maxCardHeight)
        scroll.frame = CGRect(x: 0.0, y: headerHeight + 1.0, width: cardWidth, height: cardHeight - headerHeight - 1.0)

        // Next to the button, on the side with more room, kept inside the safe area.
        let buttonFrame = button.frame
        var cardX: CGFloat
        if buttonFrame.midX > window.bounds.midX {
            cardX = buttonFrame.minX - 12.0 - cardWidth
        } else {
            cardX = buttonFrame.maxX + 12.0
        }
        cardX = min(max(cardX, insets.left + 12.0), window.bounds.width - insets.right - 12.0 - cardWidth)
        var cardY = buttonFrame.midY - cardHeight / 2.0
        cardY = min(max(cardY, insets.top + 12.0), window.bounds.height - insets.bottom - 12.0 - cardHeight)
        card.frame = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        blur.frame = card.bounds

        if let lowest = window.buttons.first {
            window.insertSubview(container, belowSubview: lowest)
        } else {
            window.addSubview(container)
        }
        window.panelContainer = container
        self.panelContainer = container

        if !animated {
            return
        }
        container.alpha = 0.0
        let anchorInContainer = window.convert(buttonFrame.center, to: container)
        let dx = anchorInContainer.x - card.center.x
        let dy = anchorInContainer.y - card.center.y
        card.transform = CGAffineTransform(translationX: dx * 0.12, y: dy * 0.12).scaledBy(x: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4, options: [], animations: {
            container.alpha = 1.0
            card.transform = .identity
        })
    }

    private func makeActionRow(icon: String, iconColor: UIColor, title: String, selected: Bool, width: CGFloat, height: CGFloat) -> UIButton {
        let row = UIButton(type: .custom)
        row.accessibilityLabel = title

        let chip = UILabel(frame: CGRect(x: 14.0, y: (height - 32.0) / 2.0, width: 32.0, height: 32.0))
        chip.text = icon
        chip.font = UIFont.systemFont(ofSize: 17.0)
        chip.textAlignment = .center
        chip.backgroundColor = iconColor.withAlphaComponent(selected ? 0.95 : 0.16)
        chip.layer.cornerRadius = 9.0
        chip.layer.cornerCurve = .continuous
        chip.layer.masksToBounds = true
        chip.isUserInteractionEnabled = false
        row.addSubview(chip)

        let label = UILabel(frame: CGRect(x: 56.0, y: 0.0, width: width - 92.0, height: height))
        label.text = title
        label.textColor = VCPalette.primaryText
        label.font = UIFont.systemFont(ofSize: 16.0, weight: selected ? .semibold : .regular)
        label.isUserInteractionEnabled = false
        row.addSubview(label)

        if selected {
            let check = UILabel(frame: CGRect(x: width - 40.0, y: 0.0, width: 26.0, height: height))
            check.text = "✓"
            check.textColor = VCPalette.accent
            check.font = UIFont.systemFont(ofSize: 17.0, weight: .bold)
            check.isUserInteractionEnabled = false
            row.addSubview(check)
        }

        row.addTarget(row, action: #selector(UIButton.vcFlash), for: .touchDown)
        return row
    }

    private func makeNavigationRow(icon: String, title: String, value: String, width: CGFloat, height: CGFloat) -> UIButton {
        let row = UIButton(type: .custom)
        row.accessibilityLabel = "\(title): \(value)"
        let iconLabel = UILabel(frame: CGRect(x: 56.0, y: 0.0, width: 22.0, height: height))
        iconLabel.text = icon
        iconLabel.font = UIFont.systemFont(ofSize: 14.0)
        iconLabel.isUserInteractionEnabled = false
        row.addSubview(iconLabel)
        let titleLabel = UILabel(frame: CGRect(x: 80.0, y: 0.0, width: width - 200.0, height: height))
        titleLabel.text = title
        titleLabel.textColor = VCPalette.secondaryText
        titleLabel.font = UIFont.systemFont(ofSize: 14.0)
        titleLabel.isUserInteractionEnabled = false
        row.addSubview(titleLabel)
        let valueLabel = UILabel(frame: CGRect(x: width - 150.0, y: 0.0, width: 118.0, height: height))
        valueLabel.text = value
        valueLabel.textAlignment = .right
        valueLabel.textColor = VCPalette.green
        valueLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        valueLabel.isUserInteractionEnabled = false
        row.addSubview(valueLabel)
        let chevron = UILabel(frame: CGRect(x: width - 28.0, y: 0.0, width: 16.0, height: height))
        chevron.text = "›"
        chevron.textColor = VCPalette.secondaryText
        chevron.font = UIFont.systemFont(ofSize: 20.0)
        chevron.isUserInteractionEnabled = false
        row.addSubview(chevron)
        row.addTarget(row, action: #selector(UIButton.vcFlash), for: .touchDown)
        return row
    }

    private func makeCheckRow(title: String, checked: Bool, isEnabled: Bool, width: CGFloat, height: CGFloat, target: RowActionTarget) -> UIView {
        let row = UIButton(type: .custom)
        row.isEnabled = isEnabled
        row.accessibilityLabel = title
        let circle = UIView(frame: CGRect(x: 16.0, y: (height - 22.0) / 2.0, width: 22.0, height: 22.0))
        circle.layer.cornerRadius = 11.0
        circle.layer.borderWidth = 1.5
        circle.layer.borderColor = UIColor(white: 1.0, alpha: isEnabled ? 0.4 : 0.15).cgColor
        circle.isUserInteractionEnabled = false
        row.addSubview(circle)
        let fill = UILabel(frame: circle.bounds)
        fill.text = "✓"
        fill.textAlignment = .center
        fill.textColor = .white
        fill.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
        fill.backgroundColor = VCPalette.green
        fill.layer.cornerRadius = 11.0
        fill.layer.masksToBounds = true
        fill.isHidden = !checked
        fill.alpha = isEnabled ? 1.0 : 0.4
        circle.addSubview(fill)
        target.checkView = fill
        let label = UILabel(frame: CGRect(x: 50.0, y: 0.0, width: width - 66.0, height: height))
        label.text = title
        label.textColor = isEnabled ? VCPalette.primaryText : VCPalette.disabledText
        label.font = UIFont.systemFont(ofSize: 15.0)
        label.isUserInteractionEnabled = false
        row.addSubview(label)
        row.addTarget(target, action: #selector(RowActionTarget.checkTapped), for: .touchUpInside)
        return row
    }

    private func makeToggleRow(icon: String, iconColor: UIColor, title: String, subtitle: String?, isOn: Bool, isEnabled: Bool, width: CGFloat, target: RowActionTarget) -> UIView {
        let switchView = UISwitch()
        switchView.isOn = isOn
        switchView.isEnabled = isEnabled
        switchView.onTintColor = VCPalette.green
        switchView.addTarget(target, action: #selector(RowActionTarget.switchChanged(_:)), for: .valueChanged)
        let switchSize = switchView.intrinsicContentSize

        let textLeft: CGFloat = 56.0
        let textWidth = width - textLeft - 12.0 - switchSize.width - 14.0
        let titleLabel = UILabel()
        titleLabel.numberOfLines = 0
        titleLabel.text = title
        titleLabel.textColor = isEnabled ? VCPalette.primaryText : VCPalette.disabledText
        titleLabel.font = UIFont.systemFont(ofSize: 16.0)
        let titleSize = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))

        var subtitleLabel: UILabel?
        var subtitleSize = CGSize()
        if let subtitle = subtitle {
            let label = UILabel()
            label.numberOfLines = 0
            label.text = subtitle
            label.textColor = isEnabled ? VCPalette.secondaryText : VCPalette.disabledText
            label.font = UIFont.systemFont(ofSize: 12.0)
            subtitleSize = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            subtitleLabel = label
        }

        let verticalPadding: CGFloat = 12.0
        let textHeight = titleSize.height + (subtitleLabel != nil ? 3.0 + subtitleSize.height : 0.0)
        let height = max(54.0, textHeight + verticalPadding * 2.0)

        let row = UIView(frame: CGRect(x: 0.0, y: 0.0, width: width, height: height))

        let chip = UILabel(frame: CGRect(x: 14.0, y: (height - 32.0) / 2.0, width: 32.0, height: 32.0))
        chip.text = icon
        chip.font = UIFont.systemFont(ofSize: 16.0)
        chip.textAlignment = .center
        chip.backgroundColor = iconColor.withAlphaComponent(isEnabled ? 0.22 : 0.1)
        chip.layer.cornerRadius = 9.0
        chip.layer.cornerCurve = .continuous
        chip.layer.masksToBounds = true
        chip.alpha = isEnabled ? 1.0 : 0.5
        row.addSubview(chip)

        var textY = floor((height - textHeight) / 2.0)
        titleLabel.frame = CGRect(x: textLeft, y: textY, width: textWidth, height: titleSize.height)
        row.addSubview(titleLabel)
        textY += titleSize.height + 3.0
        if let subtitleLabel = subtitleLabel {
            subtitleLabel.frame = CGRect(x: textLeft, y: textY, width: textWidth, height: subtitleSize.height)
            row.addSubview(subtitleLabel)
        }
        switchView.frame = CGRect(x: width - 12.0 - switchSize.width, y: floor((height - switchSize.height) / 2.0), width: switchSize.width, height: switchSize.height)
        row.addSubview(switchView)
        return row
    }

    private func hidePanel() {
        guard let container = self.panelContainer else {
            return
        }
        self.panelContainer = nil
        self.window?.panelContainer = nil
        UIView.animate(withDuration: 0.18, animations: {
            container.alpha = 0.0
        }, completion: { [weak self] _ in
            container.removeFromSuperview()
            if self?.panelContainer == nil {
                self?.panelTargets.removeAll()
            }
        })
    }

    @objc private func backgroundTapped() {
        self.hidePanel()
    }

    // MARK: - Dragging and position

    @objc private func handleVoicePan(_ recognizer: UIPanGestureRecognizer) {
        self.handlePan(recognizer, kind: .voice)
    }

    @objc private func handleAdminPan(_ recognizer: UIPanGestureRecognizer) {
        self.handlePan(recognizer, kind: .admin)
    }

    private func handlePan(_ recognizer: UIPanGestureRecognizer, kind: ButtonKind) {
        guard let button = self.button(kind), let window = self.window else {
            return
        }
        switch recognizer.state {
        case .began:
            self.hidePanel()
            self.panStartCenter = button.center
        case .changed:
            let translation = recognizer.translation(in: window)
            button.center = CGPoint(x: self.panStartCenter.x + translation.x, y: self.panStartCenter.y + translation.y)
        case .ended, .cancelled, .failed:
            self.snapToEdge(kind)
        default:
            break
        }
    }

    private func allowedRect() -> CGRect {
        guard let window = self.window else {
            return CGRect()
        }
        let insets = window.safeAreaInsets
        let margin: CGFloat = 8.0
        let half = self.buttonSize / 2.0
        return CGRect(
            x: insets.left + margin + half,
            y: insets.top + margin + half,
            width: max(0.0, window.bounds.width - insets.left - insets.right - margin * 2.0 - half * 2.0),
            height: max(0.0, window.bounds.height - insets.top - insets.bottom - margin * 2.0 - half * 2.0)
        )
    }

    private func snapToEdge(_ kind: ButtonKind) {
        guard let button = self.button(kind) else {
            return
        }
        let rect = self.allowedRect()
        var center = button.center
        center.x = center.x < rect.midX ? rect.minX : rect.maxX
        center.y = min(max(center.y, rect.minY), rect.maxY)
        UIView.animate(withDuration: 0.25, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
            button.center = center
        }, completion: nil)
        self.savePosition(center, kind: kind)
    }

    private func clampButtonsIntoView() {
        guard let window = self.window, !window.bounds.isEmpty else {
            return
        }
        let rect = self.allowedRect()
        for kind in [ButtonKind.voice, ButtonKind.admin] {
            guard let button = self.button(kind) else {
                continue
            }
            var center = button.center
            center.x = min(max(center.x, rect.minX), rect.maxX)
            center.y = min(max(center.y, rect.minY), rect.maxY)
            if center != button.center {
                button.center = center
            }
        }
    }

    private func savePosition(_ center: CGPoint, kind: ButtonKind) {
        guard let window = self.window, window.bounds.width > 0.0, window.bounds.height > 0.0 else {
            return
        }
        // Stored as a fraction of the screen so it survives rotation and different devices.
        UserDefaults.standard.set(Double(center.x / window.bounds.width), forKey: kind.positionPrefix + "X")
        UserDefaults.standard.set(Double(center.y / window.bounds.height), forKey: kind.positionPrefix + "Y")
    }

    private func restorePosition(_ kind: ButtonKind) {
        guard let button = self.button(kind), let window = self.window else {
            return
        }
        let defaults = UserDefaults.standard
        let rect = self.allowedRect()
        if defaults.object(forKey: kind.positionPrefix + "X") != nil {
            let x = CGFloat(defaults.double(forKey: kind.positionPrefix + "X")) * window.bounds.width
            let y = CGFloat(defaults.double(forKey: kind.positionPrefix + "Y")) * window.bounds.height
            button.center = CGPoint(x: x, y: y)
        } else {
            // Default: right edge, clear of the chat input panel.
            button.center = CGPoint(x: rect.maxX, y: rect.minY + rect.height * kind.defaultYFraction)
        }
        self.clampButtonsIntoView()
    }
}

private extension UIButton {
    @objc func vcFlash() {
        let highlight = UIColor(white: 1.0, alpha: 0.08)
        self.backgroundColor = highlight
        UIView.animate(withDuration: 0.3) {
            self.backgroundColor = .clear
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        return CGPoint(x: self.midX, y: self.midY)
    }
}
