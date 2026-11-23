import Foundation
import UIKit

/// A window above the app that only catches touches on the voice button itself.
/// It deliberately has no root view controller, so it never takes over the status bar
/// or the interface orientation of the main window.
private final class VoiceChangerPassthroughWindow: UIWindow {
    weak var button: UIView?
    var layoutUpdated: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
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
public final class VoiceChangerOverlay {
    public static let shared = VoiceChangerOverlay()

    private static let compactKey = "voiceChanger.compactButton"
    private static let positionXKey = "voiceChanger.buttonX"
    private static let positionYKey = "voiceChanger.buttonY"

    private var window: VoiceChangerPassthroughWindow?
    private var button: UIButton?
    private var isCompact: Bool = UserDefaults.standard.bool(forKey: VoiceChangerOverlay.compactKey)
    private var panStartCenter: CGPoint = CGPoint()

    private init() {
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
        button.showsMenuAsPrimaryAction = true
        window.addSubview(button)
        window.button = button

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        button.addGestureRecognizer(pan)

        window.layoutUpdated = { [weak self] in
            self?.clampButtonIntoView(save: false)
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
        button.menu = self.makeMenu()
        self.clampButtonIntoView(save: false)
    }

    private func makeMenu() -> UIMenu {
        let current = VoiceChanger.shared.effect

        var voiceActions: [UIMenuElement] = []
        for effect in VoiceChangerEffect.allCases {
            let action = UIAction(title: "\(effect.emoji)  \(effect.title)", state: effect == current ? .on : .off) { _ in
                VoiceChanger.shared.setEffect(effect)
            }
            voiceActions.append(action)
        }
        let voices = UIMenu(title: "", options: .displayInline, children: voiceActions)

        let sizeAction = UIAction(title: self.isCompact ? "Збільшити кнопку" : "Зменшити кнопку", image: UIImage(systemName: self.isCompact ? "plus.magnifyingglass" : "minus.magnifyingglass")) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.isCompact = !self.isCompact
            UserDefaults.standard.set(self.isCompact, forKey: VoiceChangerOverlay.compactKey)
            self.applyAppearance()
        }
        let settings = UIMenu(title: "", options: .displayInline, children: [sizeAction])

        let subtitle = current == .none ? "Голос не змінюється" : "Зараз: \(current.title)"
        return UIMenu(title: "Голос для дзвінків, голосових і кружечків\n\(subtitle)", children: [voices, settings])
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let button = self.button, let window = self.window else {
            return
        }
        switch recognizer.state {
        case .began:
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
