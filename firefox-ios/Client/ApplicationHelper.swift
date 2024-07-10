// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Common

protocol ApplicationHelper {
    func openSettings()
    func open(_ url: URL)
    func open(_ url: URL, inWindow: WindowUUID)
    func closeTab(_ url: URL) async
}

/// UIApplication.shared wrapper
struct DefaultApplicationHelper: ApplicationHelper {
    func openSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:])
    }

    /// Convenience. Opens a URL with the application.
    ///
    /// On iPadOS if more than one window is open, the OS will
    /// determine which UIScene the URL is delivered to.
    /// - Parameter url: the URL to open.
    func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    /// Opens a URL within a specific target window (UIScene).
    ///
    /// Opens a URL within a specific window on iPadOS, identified
    /// with the provided window UUID. If no window matching the
    /// UUID is found, the URL is opened as usual via UIApplication.open().
    ///
    /// - Parameters:
    ///   - url: the URL to open.
    ///   - inWindow: the UUID of the window to open the URL.
    func open(_ url: URL, inWindow: WindowUUID) {
        let foundTargetScene = UIApplication.shared.connectedScenes.contains(where: {
            guard let delegate = $0.delegate as? SceneDelegate,
                  delegate.sceneCoordinator?.windowUUID == inWindow else { return false }
            delegate.handleOpenURL(url)
            return true
        })
        if !foundTargetScene {
            open(url)
        }
    }

    /// Closes the first tab that matches the url passed in
    /// This is most likely from other clients connected to the same
    /// account requesting to close the tab on this device
    ///
    /// - Parameters:
    ///   - url: the URL requested to be closed
    func closeTab(_ url: URL) async {
    // We need to get all the windows/tabs and then find the url that was requested to close
        let windowManager = AppContainer.shared.resolve() as WindowManager
        for tabManager in windowManager.allWindowTabManagers() {
                if await tabManager.removeTabByUrl(url) {
                    break
                }
        }
    }
}
