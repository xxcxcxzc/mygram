import Foundation
import UIKit

/// A window above the app that only catches touches on the voice button, or anywhere while the
/// voice panel is open. It deliberately has no root view controller, so it never takes over the
/// status bar or the interface orientation of the main window. Because of that it cannot present
/// system menus or alerts (UIMenu silently does nothing here), so the panel is a plain view.
private final class VoiceChangerPassthroughWindow: UIWindow {
    weak var button: UIView?
    weak var panelContainer: UIView?
    var layoutUpdated: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let panelContainer = self.panelContainer, !panelContainer.isHidden {
            return super.hitTest(point, with: event)
        }
        guard let button = self.button, !button.isHidden, button.alpha > 0.01 else {
            return nil
        }
        let local = self.convert(point, to: button)
        if button.bounds.insetBy(dx: -6.0, dy: -6.0).contains(local) {
            return button
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutUpdated?()
    }
}

/// The floating 🎭 button. Tap: choose a voice. Drag: move it to another place on the screen.
/// It stays on top of every screen, including chats, voice/round-video recording and calls.
public final class VoiceChangerOverlay: NSObject {
    public static let shared = VoiceChangerOverlay()

    private static let compactKey = "voiceChanger.compactButton"
    private static let positionXKey = "voiceChanger.buttonX"
    private static let positionYKey = "voiceChanger.buttonY"

    private var window: VoiceChangerPassthroughWindow?
    private var button: UIButton?
    private var panelContainer: UIView?
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

        let button = UIButton(type: .custom)
        button.layer.masksToBounds = true
        button.layer.borderWidth = 1.0
        button.layer.borderColor = UIColor(white: 1.0, alpha: 0.35).cgColor
        button.titleLabel?.font = UIFont.systemFont(ofSize: 26.0)
        button.accessibilityLabel = "Зміна голосу"
        button.addTarget(self, action: #selector(self.buttonTapped), for: .touchUpInside)
        window.addSubview(button)
        window.button = button

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        button.addGestureRecognizer(pan)

        window.layoutUpdated = { [weak self] in
            guard let self = self else {
                return
            }
            self.clampButtonIntoView(save: false)
            if let panelContainer = self.panelContainer, let window = self.window {
                panelContainer.frame = window.bounds
            }
        }

        self.window = window
        self.button = button

        self.applyAppearance()
        self.restorePosition()
        window.isHidden = false

        VoiceChanger.shared.addObserver { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private var buttonSize: CGFloat {
        return self.isCompact ? 34.0 : 52.0
    }

    private func applyAppearance() {
        guard let button = self.button else {
            return
        }
        let effect = VoiceChanger.shared.effect
        let center = button.frame.isEmpty ? nil : button.center
        let size = self.buttonSize
        button.bounds = CGRect(x: 0.0, y: 0.0, width: size, height: size)
        if let center = center {
            button.center = center
        }
        button.layer.cornerRadius = size / 2.0
        button.titleLabel?.font = UIFont.systemFont(ofSize: self.isCompact ? 17.0 : 26.0)
        button.setTitle(effect.emoji, for: .normal)
        if effect == .none {
            button.backgroundColor = UIColor(white: 0.08, alpha: self.isCompact ? 0.45 : 0.7)
        } else {
            button.backgroundColor = UIColor(red: 0.45, green: 0.2, blue: 0.95, alpha: 0.9)
        }
        button.alpha = self.isCompact && effect == .none ? 0.6 : 1.0
        self.clampButtonIntoView(save: false)
    }

    // MARK: - Voice panel

    @objc private func buttonTapped() {
        if self.panelContainer != nil {
            self.hidePanel()
        } else {
            self.showPanel()
        }
    }

    private func showPanel() {
        guard let window = self.window, let button = self.button else {
            return
        }

        let container = UIView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .clear

        // The dimming view is a sibling below the card, so its tap recognizer never sees (and
        // never cancels) taps on the rows. It must render something: a fully clear view
        // receives no real touches.
        let dim = UIView(frame: container.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor(white: 0.0, alpha: 0.3)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.backgroundTapped)))
        container.addSubview(dim)

        let card = UIView()
        card.backgroundColor = UIColor(white: 0.12, alpha: 0.97)
        card.layer.cornerRadius = 16.0
        card.layer.masksToBounds = true
        container.addSubview(card)

        let current = VoiceChanger.shared.effect
        let rowHeight: CGFloat = 46.0
        let titleHeight: CGFloat = 52.0
        let cardWidth: CGFloat = min(280.0, window.bounds.width - 32.0)

        let titleLabel = UILabel()
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.textColor = UIColor(white: 1.0, alpha: 0.6)
        titleLabel.font = UIFont.systemFont(ofSize: 13.0)
        titleLabel.text = "Голос для дзвінків, голосових і кружечків"
        titleLabel.frame = CGRect(x: 12.0, y: 0.0, width: cardWidth - 24.0, height: titleHeight)
        card.addSubview(titleLabel)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        card.addSubview(scroll)

        var y: CGFloat = 0.0
        for effect in VoiceChangerEffect.allCases {
            let row = self.makeRow(title: "\(effect.emoji)   \(effect.title)", selected: effect == current, width: cardWidth, height: rowHeight)
            row.tag = Int(effect.rawValue)
            row.addTarget(self, action: #selector(self.effectRowTapped(_:)), for: .touchUpInside)
            row.frame = CGRect(x: 0.0, y: y, width: cardWidth, height: rowHeight)
            scroll.addSubview(row)
            y += rowHeight
        }
        let separator = UIView(frame: CGRect(x: 0.0, y: y, width: cardWidth, height: 6.0))
        separator.backgroundColor = UIColor(white: 0.0, alpha: 0.35)
        scroll.addSubview(separator)
        y += 6.0
        let sizeRow = self.makeRow(title: self.isCompact ? "🔍   Збільшити кнопку" : "🔍   Зменшити кнопку", selected: false, width: cardWidth, height: rowHeight)
        sizeRow.addTarget(self, action: #selector(self.sizeRowTapped), for: .touchUpInside)
        sizeRow.frame = CGRect(x: 0.0, y: y, width: cardWidth, height: rowHeight)
        scroll.addSubview(sizeRow)
        y += rowHeight
        scroll.contentSize = CGSize(width: cardWidth, height: y)

        let insets = window.safeAreaInsets
        let maxCardHeight = window.bounds.height - insets.top - insets.bottom - 24.0
        let cardHeight = min(titleHeight + y, maxCardHeight)
        scroll.frame = CGRect(x: 0.0, y: titleHeight, width: cardWidth, height: cardHeight - titleHeight)

        // Next to the button, on the side with more room, kept inside the safe area.
        let buttonFrame = button.frame
        var cardX: CGFloat
        if buttonFrame.midX > window.bounds.midX {
            cardX = buttonFrame.minX - 10.0 - cardWidth
        } else {
            cardX = buttonFrame.maxX + 10.0
        }
        cardX = min(max(cardX, insets.left + 12.0), window.bounds.width - insets.right - 12.0 - cardWidth)
        var cardY = buttonFrame.midY - cardHeight / 2.0
        cardY = min(max(cardY, insets.top + 12.0), window.bounds.height - insets.bottom - 12.0 - cardHeight)
        card.frame = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)

        window.insertSubview(container, belowSubview: button)
        window.panelContainer = container
        self.panelContainer = container

        container.alpha = 0.0
        card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.18, animations: {
            container.alpha = 1.0
            card.transform = .identity
        })
    }

    private func makeRow(title: String, selected: Bool, width: CGFloat, height: CGFloat) -> UIButton {
        let row = UIButton(type: .custom)
        row.accessibilityLabel = title
        let label = UILabel(frame: CGRect(x: 16.0, y: 0.0, width: width - 56.0, height: height))
        label.text = title
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 17.0, weight: selected ? .semibold : .regular)
        label.isUserInteractionEnabled = false
        row.addSubview(label)
        row.backgroundColor = selected ? UIColor(red: 0.45, green: 0.2, blue: 0.95, alpha: 0.55) : .clear
        if selected {
            let check = UILabel(frame: CGRect(x: width - 36.0, y: 0.0, width: 24.0, height: height))
            check.text = "✓"
            check.textColor = .white
            check.font = UIFont.systemFont(ofSize: 18.0, weight: .bold)
            check.isUserInteractionEnabled = false
            row.addSubview(check)
        }
        return row
    }

    private func hidePanel() {
        guard let container = self.panelContainer else {
            return
        }
        self.panelContainer = nil
        self.window?.panelContainer = nil
        UIView.animate(withDuration: 0.15, animations: {
            container.alpha = 0.0
        }, completion: { _ in
            container.removeFromSuperview()
        })
    }

    @objc private func backgroundTapped() {
        self.hidePanel()
    }

    @objc private func effectRowTapped(_ sender: UIButton) {
        if let effect = VoiceChangerEffect(rawValue: Int32(sender.tag)) {
            VoiceChanger.shared.setEffect(effect)
        }
        self.hidePanel()
    }

    @objc private func sizeRowTapped() {
        self.isCompact = !self.isCompact
        UserDefaults.standard.set(self.isCompact, forKey: VoiceChangerOverlay.compactKey)
        self.applyAppearance()
        self.hidePanel()
    }

    // MARK: - Dragging and position

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let button = self.button, let window = self.window else {
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
            self.snapToEdge()
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

    private func snapToEdge() {
        guard let button = self.button else {
            return
        }
        let rect = self.allowedRect()
        var center = button.center
        center.x = center.x < rect.midX ? rect.minX : rect.maxX
        center.y = min(max(center.y, rect.minY), rect.maxY)
        UIView.animate(withDuration: 0.25, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
            button.center = center
        }, completion: nil)
        self.savePosition(center)
    }

    private func clampButtonIntoView(save: Bool) {
        guard let button = self.button, let window = self.window, !window.bounds.isEmpty else {
            return
        }
        let rect = self.allowedRect()
        var center = button.center
        center.x = min(max(center.x, rect.minX), rect.maxX)
        center.y = min(max(center.y, rect.minY), rect.maxY)
        if center != button.center {
            button.center = center
        }
        if save {
            self.savePosition(center)
        }
    }

    private func savePosition(_ center: CGPoint) {
        guard let window = self.window, window.bounds.width > 0.0, window.bounds.height > 0.0 else {
            return
        }
        // Stored as a fraction of the screen so it survives rotation and different devices.
        UserDefaults.standard.set(Double(center.x / window.bounds.width), forKey: VoiceChangerOverlay.positionXKey)
        UserDefaults.standard.set(Double(center.y / window.bounds.height), forKey: VoiceChangerOverlay.positionYKey)
    }

    private func restorePosition() {
        guard let button = self.button, let window = self.window else {
            return
        }
        let defaults = UserDefaults.standard
        let rect = self.allowedRect()
        if defaults.object(forKey: VoiceChangerOverlay.positionXKey) != nil {
            let x = CGFloat(defaults.double(forKey: VoiceChangerOverlay.positionXKey)) * window.bounds.width
            let y = CGFloat(defaults.double(forKey: VoiceChangerOverlay.positionYKey)) * window.bounds.height
            button.center = CGPoint(x: x, y: y)
        } else {
            // Default: right edge, a bit above the middle (clear of the chat input panel).
            button.center = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.38)
        }
        self.clampButtonIntoView(save: false)
    }
}
