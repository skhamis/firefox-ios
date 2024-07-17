// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Storage
import Common
import Shared
import Redux

class RemoteTabsPanelMiddleware {
    private let profile: Profile
    var notificationCenter: NotificationProtocol

    var hasSyncableAccount: Bool {
        return profile.hasSyncableAccount()
    }

    init(profile: Profile = AppContainer.shared.resolve(),
         notificationCenter: NotificationProtocol = NotificationCenter.default) {
        self.profile = profile
        self.notificationCenter = notificationCenter
        observeNotifications()
    }

    lazy var remoteTabsPanelProvider: Middleware<AppState> = { [self] state, action in
        let uuid = action.windowUUID
        guard let action = action as? RemoteTabsPanelAction else { return }
        switch action.actionType {
        case RemoteTabsPanelActionType.panelDidAppear:
            self.getSyncState(window: uuid)
            let accountChangeAction = TabTrayAction(hasSyncableAccount: self.hasSyncableAccount,
                                                    windowUUID: uuid,
                                                    actionType: TabTrayActionType.firefoxAccountChanged)
            store.dispatch(accountChangeAction)
        case RemoteTabsPanelActionType.refreshTabs:
            self.getSyncState(window: uuid)
        case RemoteTabsPanelActionType.refreshTabsWithCache:
            self.getSyncState(window: uuid, useCache: true)
        default:
            break
        }
    }

    // MARK: - Internal Utilities
    private func getSyncState(window: WindowUUID, useCache: Bool = false) {
        ensureMainThread { [self] in
            guard self.hasSyncableAccount else {
                let action = RemoteTabsPanelAction(reason: .notLoggedIn,
                                                   windowUUID: window,
                                                   actionType: RemoteTabsPanelActionType.refreshDidFail)
                store.dispatch(action)
                return
            }

            let syncEnabled = (profile.prefs.boolForKey(PrefsKeys.TabSyncEnabled) == true)
            guard syncEnabled else {
                let action = RemoteTabsPanelAction(reason: .syncDisabledByUser,
                                                   windowUUID: window,
                                                   actionType: RemoteTabsPanelActionType.refreshDidFail)
                store.dispatch(action)
                return
            }

            // If above checks have succeeded, we know we can perform the tab refresh. We
            // need to update the State to .refreshing since there are implications for being
            // in the middle of a refresh (pull-to-refresh shouldn't trigger a new update etc.)
            let action = RemoteTabsPanelAction(windowUUID: window,
                                               actionType: RemoteTabsPanelActionType.refreshDidBegin)
            store.dispatch(action)

            getRemoteTabs(window: window, useCache: useCache)
        }
    }

    private func getRemoteTabs(window: WindowUUID, useCache: Bool = false) {
        let fetchClientsAndTabs: (@escaping ([ClientAndTabs]?) -> Void) -> Void
            = useCache ? profile.getCachedClientsAndTabs : profile.getClientsAndTabs
        fetchClientsAndTabs { result in
            guard let clientAndTabs = result else {
                let action = RemoteTabsPanelAction(reason: .failedToSync,
                                                   windowUUID: window,
                                                   actionType: RemoteTabsPanelActionType.refreshDidFail)
                store.dispatch(action)
                return
            }
            let action = RemoteTabsPanelAction(clientAndTabs: clientAndTabs,
                                               windowUUID: window,
                                               actionType: RemoteTabsPanelActionType.refreshDidSucceed)
            store.dispatch(action)
        }
    }

    // MARK: - Notifications
    private func observeNotifications() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self,
                                       selector: #selector(notificationReceived),
                                       name: .FirefoxAccountChanged,
                                       object: nil)
        notificationCenter.addObserver(self,
                                       selector: #selector(notificationReceived),
                                       name: .ProfileDidFinishSyncing,
                                       object: nil)
    }

    @objc
    func notificationReceived(_ notification: Notification) {
        switch notification.name {
        case .FirefoxAccountChanged,
                .ProfileDidFinishSyncing:
            // This update occurs independently of any specific window, so for now we send `.unavailable`
            // as the window UUID. Reducers responding to these types of messages need to use care not to
            // propagate that UUID in any subsequent actions or state changes.
            let accountChangeAction = TabTrayAction(hasSyncableAccount: hasSyncableAccount,
                                                    windowUUID: WindowUUID.unavailable,
                                                    actionType: TabTrayActionType.firefoxAccountChanged)
            store.dispatch(accountChangeAction)
        default: break
        }
    }
}
