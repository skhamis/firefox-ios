// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import TabDataStore
import Storage
import Common
import Shared

// This class subclasses the legacy tab manager temporarily so we can
// gradually migrate to the new system
class TabManagerImplementation: LegacyTabManager, Notifiable, WindowSimpleTabsProvider {
    private let tabDataStore: TabDataStore
    private let tabSessionStore: TabSessionStore
    private let imageStore: DiskImageStore?
    private let tabMigration: TabMigrationUtility
    private var tabsTelemetry = TabsTelemetry()
    private let windowManager: WindowManager
    var notificationCenter: NotificationProtocol
    var inactiveTabsManager: InactiveTabsManagerProtocol

    override var normalActiveTabs: [Tab] {
        let inactiveTabs = getInactiveTabs()
        let activeTabs = tabs.filter { $0.isPrivate == false && !inactiveTabs.contains($0) }
        return activeTabs
    }

    init(profile: Profile,
         imageStore: DiskImageStore = AppContainer.shared.resolve(),
         logger: Logger = DefaultLogger.shared,
         uuid: WindowUUID,
         tabDataStore: TabDataStore? = nil,
         tabSessionStore: TabSessionStore = DefaultTabSessionStore(),
         tabMigration: TabMigrationUtility? = nil,
         notificationCenter: NotificationProtocol = NotificationCenter.default,
         inactiveTabsManager: InactiveTabsManagerProtocol = InactiveTabsManager(),
         windowManager: WindowManager = AppContainer.shared.resolve()) {
        let dataStore =  tabDataStore ?? DefaultTabDataStore(logger: logger, fileManager: DefaultTabFileManager())
        self.tabDataStore = dataStore
        self.tabSessionStore = tabSessionStore
        self.imageStore = imageStore
        self.tabMigration = tabMigration ?? DefaultTabMigrationUtility(tabDataStore: dataStore)
        self.notificationCenter = notificationCenter
        self.inactiveTabsManager = inactiveTabsManager
        self.windowManager = windowManager
        super.init(profile: profile, uuid: uuid)

        setupNotifications(forObserver: self,
                           observing: [UIApplication.willResignActiveNotification,
                                       .TabMimeTypeDidSet])
    }

    // MARK: - Restore tabs

    override func restoreTabs(_ forced: Bool = false) {
        guard !isRestoringTabs,
              forced || tabs.isEmpty
        else {
            logger.log("No restore tabs running",
                       level: .debug,
                       category: .tabs)
            return
        }

        logger.log("Tabs restore started being force; \(forced), with empty tabs; \(tabs.isEmpty)",
                   level: .debug,
                   category: .tabs)

        guard !AppConstants.isRunningUITests,
              !DebugSettingsBundleOptions.skipSessionRestore
        else {
            if tabs.isEmpty {
                let newTab = addTab()
                selectTab(newTab)
            }
            return
        }

        isRestoringTabs = true
        AppEventQueue.started(.tabRestoration(windowUUID))

        guard tabMigration.shouldRunMigration else {
            logger.log("Not running the migration",
                       level: .debug,
                       category: .tabs)
            restoreOnly()
            return
        }

        logger.log("Running the migration",
                   level: .debug,
                   category: .tabs)
        migrateAndRestore()
    }

    private func migrateAndRestore() {
        Task {
            await buildTabRestore(window: await tabMigration.runMigration(for: windowUUID))
            logger.log("Tabs restore ended after migration", level: .debug, category: .tabs)
            logger.log("Normal tabs count; \(normalTabs.count), Inactive tabs count; \(inactiveTabs.count), Private tabs count; \(privateTabs.count)", level: .debug, category: .tabs)
        }
    }

    private func restoreOnly() {
        tabs = [Tab]()
        Task {
            await buildTabRestore(window: await self.tabDataStore.fetchWindowData(uuid: windowUUID))
            logger.log("Tabs restore ended after fetching window data", level: .debug, category: .tabs)
            logger.log("Normal tabs count; \(normalTabs.count), Inactive tabs count; \(inactiveTabs.count), Private tabs count; \(privateTabs.count)", level: .debug, category: .tabs)
        }
    }

    private func buildTabRestore(window: WindowData?) async {
        defer {
            isRestoringTabs = false
            tabRestoreHasFinished = true
            AppEventQueue.completed(.tabRestoration(windowUUID))
        }

        let nonPrivateTabs = window?.tabData.filter { !$0.isPrivate }

        guard let windowData = window,
              let nonPrivateTabs,
              !nonPrivateTabs.isEmpty,
              tabs.isEmpty
        else {
            // Always make sure there is a single normal tab
            await generateEmptyTab()
            logger.log("There was no tabs restored, creating a normal tab",
                       level: .debug,
                       category: .tabs)

            return
        }
        await generateTabs(from: windowData)
        cleanUpUnusedScreenshots()
        cleanUpTabSessionData()

        await MainActor.run {
            for delegate in delegates {
                delegate.get()?.tabManagerDidRestoreTabs(self)
            }
        }
    }

    /// Creates the webview so needs to live on the main thread
    @MainActor
    private func generateTabs(from windowData: WindowData) async {
        var tabToSelect: Tab?

        for tabData in windowData.tabData {
            let newTab = addTab(flushToDisk: false, zombie: true, isPrivate: tabData.isPrivate)
            newTab.url = URL(string: tabData.siteUrl, invalidCharacters: false)
            newTab.lastTitle = tabData.title
            newTab.tabUUID = tabData.id.uuidString
            newTab.screenshotUUID = tabData.id
            newTab.firstCreatedTime = tabData.createdAtTime.toTimestamp()
            newTab.lastExecutedTime = tabData.lastUsedTime.toTimestamp()
            let groupData = LegacyTabGroupData(
                searchTerm: tabData.tabGroupData?.searchTerm ?? "",
                searchUrl: tabData.tabGroupData?.searchUrl ?? "",
                nextReferralUrl: tabData.tabGroupData?.nextUrl ?? "",
                tabHistoryCurrentState: tabData.tabGroupData?.tabHistoryCurrentState?.rawValue ?? ""
            )
            newTab.metadataManager?.tabGroupData = groupData

            if newTab.url == nil {
                logger.log("Tab restored has empty URL for tab id \(tabData.id.uuidString). It was last used \(tabData.lastUsedTime)",
                           level: .debug,
                           category: .tabs)
            }

            // Restore screenshot
            restoreScreenshot(tab: newTab)

            if windowData.activeTabId == tabData.id {
                tabToSelect = newTab
            }
        }

        logger.log("There was \(windowData.tabData.count) tabs restored",
                   level: .debug,
                   category: .tabs)

        selectTab(tabToSelect)

        // If tabToSelect is nil after restoration, force selection of first tab normal tab
        if tabToSelect == nil {
            guard let tabToSelect = tabs.first(where: { !$0.isPrivate }) else {
                selectTab(addTab())
                return
            }

            selectTab(tabToSelect)
        }
    }

    /// Creates the webview so needs to live on the main thread
    @MainActor
    private func generateEmptyTab() {
        let newTab = addTab()
        selectTab(newTab)
    }

    private func restoreScreenshot(tab: Tab) {
        Task {
            let screenshot = try? await imageStore?.getImageForKey(tab.tabUUID)
            tab.setScreenshot(screenshot)
        }
    }

    // MARK: - Save tabs

    override func preserveTabs() {
        // Only preserve tabs after the restore has finished
        guard tabRestoreHasFinished else { return }

        logger.log("Preserve tabs started", level: .debug, category: .tabs)
        preserveTabs(forced: false)
    }

    private func preserveTabs(forced: Bool) {
        Task {
            // This value should never be nil but we need to still treat it
            // as if it can be nil until the old code is removed
            let activeTabID = UUID(uuidString: self.selectedTab?.tabUUID ?? "") ?? UUID()
            let windowData = WindowData(id: windowUUID,
                                        activeTabId: activeTabID,
                                        tabData: self.generateTabDataForSaving())
            await tabDataStore.saveWindowData(window: windowData, forced: forced)

            // Save simple tabs, used by widget extension
            windowManager.performMultiWindowAction(.saveSimpleTabs)

            logger.log("Preserve tabs ended", level: .debug, category: .tabs)
        }
    }

    private func generateTabDataForSaving() -> [TabData] {
        let tabData = normalTabs.map { tab in
            let oldTabGroupData = tab.metadataManager?.tabGroupData
            let state = TabGroupTimerState(rawValue: oldTabGroupData?.tabHistoryCurrentState ?? "")
            let groupData = TabGroupData(searchTerm: oldTabGroupData?.tabAssociatedSearchTerm,
                                         searchUrl: oldTabGroupData?.tabAssociatedSearchUrl,
                                         nextUrl: oldTabGroupData?.tabAssociatedNextUrl,
                                         tabHistoryCurrentState: state)

            let tabId = UUID(uuidString: tab.tabUUID) ?? UUID()
            let logMessage = "for saving for tab id \(tabId). It was last used \(Date.fromTimestamp(tab.lastExecutedTime ?? 0))"
            if tab.url == nil {
                logger.log("Tab has empty tab.URL \(logMessage)",
                           level: .debug,
                           category: .tabs)
            }

            return TabData(id: tabId,
                           title: tab.lastTitle,
                           siteUrl: tab.url?.absoluteString ?? tab.lastKnownUrl?.absoluteString ?? "",
                           faviconURL: tab.faviconURL,
                           isPrivate: tab.isPrivate,
                           lastUsedTime: Date.fromTimestamp(tab.lastExecutedTime ?? 0),
                           createdAtTime: Date.fromTimestamp(tab.firstCreatedTime ?? 0),
                           tabGroupData: groupData)
        }

        let logInfo: String
        let windowCount = windowManager.windows.count
        let totalTabCount =
        (windowCount > 1 ? windowManager.allWindowTabManagers().map({ $0.normalTabs.count }).reduce(0, +) : 0)
        logInfo = (windowCount == 1) ? "(1 window)" : "(of \(totalTabCount) total tabs across \(windowCount) windows)"
        logger.log("Tab manager is preserving \(tabData.count) tabs \(logInfo)", level: .debug, category: .tabs)

        return tabData
    }

    /// storeChanges is called when a web view has finished loading a page
    override func storeChanges() {
        let windowManager: WindowManager = AppContainer.shared.resolve()
        windowManager.performMultiWindowAction(.storeTabs)
        preserveTabs()
        saveCurrentTabSessionData()
    }

    private func saveCurrentTabSessionData() {
        guard let selectedTab = self.selectedTab,
              !selectedTab.isPrivate,
              let tabSession = selectedTab.webView?.interactionState as? Data,
              let tabID = UUID(uuidString: selectedTab.tabUUID)
        else { return }

        Task {
            await self.tabSessionStore.saveTabSession(tabID: tabID, sessionData: tabSession)
        }
    }

    private func saveAllTabData() {
        // Only preserve tabs after the restore has finished
        guard tabRestoreHasFinished else { return }

        saveCurrentTabSessionData()
        preserveTabs(forced: true)
    }

    // MARK: - Select Tab

    /// This function updates the _selectedIndex.
    /// Note: it is safe to call this with `tab` and `previous` as the same tab, for use in the case
    /// where the index of the tab has changed (such as after deletion).
    override func selectTab(_ tab: Tab?, previous: Tab? = nil) {
        let url = tab?.url
        guard let tab = tab,
              let tabUUID = UUID(uuidString: tab.tabUUID)
        else {
            logger.log("Selected tab doesn't exist",
                       level: .debug,
                       category: .tabs)
            return
        }

        // Before moving to a new tab save the current tab session data in order to preserve things like scroll position
        saveCurrentTabSessionData()

        willSelectTab(url)
        Task(priority: .high) {
            var sessionData: Data?
            if !tab.isFxHomeTab {
                sessionData = await tabSessionStore.fetchTabSession(tabID: tabUUID)
            }
            await selectTabWithSession(tab: tab,
                                       previous: previous,
                                       sessionData: sessionData)

            // Default to false if the feature flag is not enabled
            var isPrivate = false
            if featureFlags.isFeatureEnabled(.feltPrivacySimplifiedUI, checking: .buildOnly) {
                isPrivate = tab.isPrivate
            }

            let action = PrivateModeAction(isPrivate: isPrivate,
                                           windowUUID: windowUUID,
                                           actionType: PrivateModeActionType.setPrivateModeTo)
            store.dispatch(action)

            didSelectTab(url)
            updateMenuItemsForSelectedTab()
        }
    }

    private func willSelectTab(_ url: URL?) {
        tabsTelemetry.startTabSwitchMeasurement()
        guard let url else { return }
        AppEventQueue.started(.selectTab(url, windowUUID))
    }

    private func didSelectTab(_ url: URL?) {
        tabsTelemetry.stopTabSwitchMeasurement()
        AppEventQueue.completed(.selectTab(url, windowUUID))
        let action = GeneralBrowserAction(selectedTabURL: url,
                                          isPrivateBrowsing: selectedTab?.isPrivate ?? false,
                                          windowUUID: windowUUID,
                                          actionType: GeneralBrowserActionType.updateSelectedTab)
        store.dispatch(action)
    }

    @MainActor
    private func selectTabWithSession(tab: Tab, previous: Tab?, sessionData: Data?) {
        let previous = previous ?? selectedTab

        previous?.metadataManager?.updateTimerAndObserving(state: .tabSwitched, isPrivate: previous?.isPrivate ?? false)
        tab.metadataManager?.updateTimerAndObserving(state: .tabSelected, isPrivate: tab.isPrivate)

        _selectedIndex = tabs.firstIndex(of: tab) ?? -1

        preserveTabs()

        selectedTab?.createWebview(with: sessionData)
        selectedTab?.lastExecutedTime = Date.now()

        delegates.forEach {
            $0.get()?.tabManager(
                self,
                didSelectedTabChange: tab,
                previous: previous,
                isRestoring: !tabRestoreHasFinished
            )
        }

        if let tab = previous {
            TabEvent.post(.didLoseFocus, for: tab)
        }
        if let tab = selectedTab {
            TabEvent.post(.didGainFocus, for: tab)
        }
        TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .tab)
    }

    // MARK: - Screenshots

    override func tabDidSetScreenshot(_ tab: Tab, hasHomeScreenshot: Bool) {
        guard tab.screenshot != nil else {
            // Remove screenshot from image store so we can use favicon
            // when a screenshot isn't available for the associated tab url
            removeScreenshot(tab: tab)
            return
        }

        storeScreenshot(tab: tab)
    }

    func storeScreenshot(tab: Tab) {
        guard let screenshot = tab.screenshot else { return }

        Task {
            try? await imageStore?.saveImageForKey(tab.tabUUID, image: screenshot)
        }
    }

    func removeScreenshot(tab: Tab) {
        Task {
            await imageStore?.deleteImageForKey(tab.tabUUID)
        }
    }

    private func cleanUpUnusedScreenshots() {
        // Clean up any screenshots that are no longer associated with a tab.
        var savedUUIDs = Set<String>()
        tabs.forEach { savedUUIDs.insert($0.screenshotUUID?.uuidString ?? "") }
        let savedUUIDsCopy = savedUUIDs
        Task {
            try? await imageStore?.clearAllScreenshotsExcluding(savedUUIDsCopy)
        }
    }

    private func cleanUpTabSessionData() {
        let liveTabs = tabs.compactMap { UUID(uuidString: $0.tabUUID) }
        Task {
            await tabSessionStore.deleteUnusedTabSessionData(keeping: liveTabs)
        }
    }

    // MARK: - Inactive tabs
    override func getInactiveTabs() -> [Tab] {
        let inactiveTabsEnabled = profile.prefs.boolForKey(PrefsKeys.FeatureFlags.InactiveTabs)
        guard inactiveTabsEnabled ?? true else { return [] }
        return inactiveTabsManager.getInactiveTabs(tabs: tabs)
    }

    @MainActor
    override func removeAllInactiveTabs() async {
        backupCloseTabs = getInactiveTabs()
        let currentModeTabs = backupCloseTabs
        for tab in currentModeTabs {
            await self.removeTab(tab.tabUUID)
        }
        storeChanges()
    }

    @MainActor
    override func undoCloseInactiveTabs() {
        tabs.append(contentsOf: backupCloseTabs)
        storeChanges()
        backupCloseTabs = [Tab]()
    }

    override func clearAllTabsHistory() {
        super.clearAllTabsHistory()
        Task {
            await tabSessionStore.deleteUnusedTabSessionData(keeping: [])
        }
    }

    @MainActor
    func closeTab(by url: URL) async {
        // Find the tab with the specified URL
        if let tabToClose = tabs.first(where: { $0.url == url }) {
            await self.removeTab(tabToClose.tabUUID)
        }
    }

    // MARK: - Update Menu Items
    private func updateMenuItemsForSelectedTab() {
        guard let selectedTab,
              var menuItems = UIMenuController.shared.menuItems
        else { return }

        if selectedTab.mimeType == MIMEType.PDF {
            // Iterate in reverse order to avoid index out of range errors when removing items
            for index in stride(from: menuItems.count - 1, through: 0, by: -1) {
                if menuItems[index].action == MenuHelperWebViewModel.selectorSearchWith ||
                    menuItems[index].action == MenuHelperWebViewModel.selectorFindInPage {
                    menuItems.remove(at: index)
                }
            }
        } else if !menuItems.contains(where: {
            $0.title == .MenuHelperSearchWithFirefox ||
            $0.title == .MenuHelperFindInPage
        }) {
            let searchItem = UIMenuItem(
                title: .MenuHelperSearchWithFirefox,
                action: MenuHelperWebViewModel.selectorSearchWith
            )
            let findInPageItem = UIMenuItem(
                title: .MenuHelperFindInPage,
                action: MenuHelperWebViewModel.selectorFindInPage
            )
            menuItems.append(contentsOf: [searchItem, findInPageItem])
        }
        UIMenuController.shared.menuItems = menuItems
    }

    // MARK: - Notifiable

    func handleNotifications(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willResignActiveNotification:
            saveAllTabData()
        case .TabMimeTypeDidSet:
            guard windowUUID == notification.windowUUID else { return }
            updateMenuItemsForSelectedTab()
        default:
            break
        }
    }

    // MARK: - WindowSimpleTabsProvider

    func windowSimpleTabs() -> [TabUUID: SimpleTab] {
        let activeTabID = UUID(uuidString: self.selectedTab?.tabUUID ?? "") ?? UUID()
        let windowData = WindowData(id: windowUUID,
                                    activeTabId: activeTabID,
                                    tabData: self.generateTabDataForSaving())
        return SimpleTab.convertToSimpleTabs(windowData.tabData)
    }
}
