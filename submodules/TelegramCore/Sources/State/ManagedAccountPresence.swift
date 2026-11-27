import Foundation
internal import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    private var settingsObserver: NSObjectProtocol?
    private var ghostHideOnline: Bool = MyGramSettings.ghostHideOnline
    private var ghostOfflineTimer: SignalKitTimer?
    private let ghostRequestDisposable = MetaDisposable()
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                self.updatePresence(value)
            }
        })
        
        // MyGram: re-send the status when ghost mode is switched on or off.
        self.settingsObserver = NotificationCenter.default.addObserver(forName: MyGramSettings.didChangeNotification, object: nil, queue: nil, using: { [weak self] _ in
            queue.async {
                guard let self = self else {
                    return
                }
                let ghostHideOnline = MyGramSettings.ghostHideOnline
                if self.ghostHideOnline != ghostHideOnline {
                    self.ghostHideOnline = ghostHideOnline
                    // Switched on: go offline now. Switched off: back to the normal status.
                    if ghostHideOnline {
                        self.updatePresence(false, force: true)
                        self.updateGhostOfflineTimer(appIsActive: self.wasOnline)
                    } else {
                        self.updatePresence(self.wasOnline, force: true)
                    }
                }
            }
        })
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
        self.ghostOfflineTimer?.invalidate()
        self.ghostRequestDisposable.dispose()
        if let settingsObserver = self.settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }
    
    private func updateGhostOfflineTimer(appIsActive: Bool) {
        if !appIsActive {
            // Leaving the app or switching to another account: one last "offline" while the
            // connection is still up, so an "online" the server set after a send doesn't linger.
            if self.ghostOfflineTimer != nil {
                self.sendGhostOffline()
            }
            self.ghostOfflineTimer?.invalidate()
            self.ghostOfflineTimer = nil
            return
        }
        self.sendGhostOffline()
        if self.ghostOfflineTimer == nil {
            let timer = SignalKitTimer(timeout: 8.0, repeat: true, completion: { [weak self] in
                guard let self = self else {
                    return
                }
                if MyGramSettings.ghostHideOnline && self.wasOnline {
                    self.sendGhostOffline()
                } else {
                    self.ghostOfflineTimer?.invalidate()
                    self.ghostOfflineTimer = nil
                }
            }, queue: self.queue)
            self.ghostOfflineTimer = timer
            timer.start()
        }
    }

    private func sendGhostOffline() {
        // Not tied to a disposable: a new send must not cancel the previous one still in flight.
        let _ = (self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }).start()
    }

    private func updatePresence(_ isOnline: Bool, force: Bool = false) {
        if MyGramSettings.ghostHideOnline && !force {
            // MyGram ghost mode: never send "online". While the app is open, keep telling the
            // server "offline", which overrides an "online" the server sets on its own (after
            // some actions) or that another session sets.
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            self.updateGhostOfflineTimer(appIsActive: isOnline)
            return
        }
        self.ghostOfflineTimer?.invalidate()
        self.ghostOfflineTimer = nil
        let request: Signal<Api.Bool, MTRpcError>
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
