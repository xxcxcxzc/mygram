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

    private func showAdminPanel() {
        let ghost = MyGramSettings.ghostHideOnline
        let rows: [PanelRow] = [
            .toggle(icon: "🗑", iconColor: UIColor(red: 0.95, green: 0.45, blue: 0.4, alpha: 1.0), title: "Видалені повідомлення", subtitle: "Не зникають з чату, а позначаються «видалено»", isOn: MyGramSettings.showDeletedMessages, isEnabled: true, handler: { [weak self] value in
                MyGramSettings.showDeletedMessages = value
                self?.applyAppearance()
            }),
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
            .toggle(icon: "🚪", iconColor: UIColor(white: 1.0, alpha: 0.14), title: "«Не в мережі» після відправки", subtitle: "Одразу після повідомлення знову ставить «не в мережі»", isOn: MyGramSettings.ghostOfflineAfterSend, isEnabled: ghost, handler: { value in
                MyGramSettings.ghostOfflineAfterSend = value
            }),
            .toggle(icon: "✓", iconColor: UIColor(white: 1.0, alpha: 0.14), title: "Прочитано лише після відповіді", subtitle: "Співрозмовник побачить «прочитано» тільки коли ти відповіси в цьому чаті", isOn: MyGramSettings.ghostNoReadReceipts, isEnabled: true, handler: { value in
                MyGramSettings.ghostNoReadReceipts = value
            })
        ]
        self.showPanel(emoji: "🛡", title: "MyGram", subtitle: "Додаткові можливості", rows: rows, anchor: .admin)
    }

    private func reloadAdminPanel() {
        guard let container = self.panelContainer else {
            return
        }
        container.removeFromSuperview()
        self.panelContainer = nil
        self.window?.panelContainer = nil
        self.panelTargets.removeAll()
        self.showAdminPanel()
        self.panelContainer?.alpha = 1.0
    }

    private func showPanel(emoji: String, title: String, subtitle: String, rows: [PanelRow], anchor: ButtonKind) {
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
