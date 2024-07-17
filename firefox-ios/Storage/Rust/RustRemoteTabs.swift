// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared
import Common

import class MozillaAppServices.TabsStore
import class MozillaAppServices.RemoteCommandStore
import enum MozillaAppServices.TabsApiError
import enum MozillaAppServices.RemoteCommand
import struct MozillaAppServices.ClientRemoteTabs
import struct MozillaAppServices.RemoteTabRecord

public class RustRemoteTabs {
    let databasePath: String
    let queue: DispatchQueue
    var store: TabsStore?
    var commandQueue: RemoteTabsCommandQueue?

    private(set) var isOpen = false
    private var didAttemptToMoveToBackup = false
    private let logger: Logger

    public init(databasePath: String,
                logger: Logger = DefaultLogger.shared) {
        self.databasePath = databasePath
        self.logger = logger

        queue = DispatchQueue(label: "RustRemoteTabs queue: \(databasePath)", attributes: [])
    }

    private func open() -> NSError? {
        store = TabsStore(path: databasePath)
        isOpen = true
        commandQueue = RemoteTabsCommandQueue()
        commandQueue?.openCommandStore(tabsStore: store!)
        return nil
    }

    private func close() -> NSError? {
        store = nil
        commandQueue = nil
        isOpen = false
        return nil
    }

    public func reopenIfClosed() -> NSError? {
        var error: NSError?

        queue.sync {
            guard !isOpen else { return }

            error = open()
        }

        return error
    }

    public func forceClose() -> NSError? {
        var error: NSError?

        queue.sync {
            guard isOpen else { return }

            error = close()
        }

        return error
    }

    public func setLocalTabs(localTabs: [RemoteTab]) -> Deferred<Maybe<Int>> {
        let deferred = Deferred<Maybe<Int>>()
        queue.async {
            guard let store = self.store else {
                let error = TabsApiError.UnexpectedTabsError(reason: "TabsStore is not available")
                deferred.fill(Maybe(failure: error as MaybeErrorType))
                return
            }
            let tabs = localTabs.map { $0.toRemoteTabRecord() }
            store.setLocalTabs(remoteTabs: tabs)
            deferred.fill(Maybe(success: tabs.count))
        }
        return deferred
    }

    public func getAll() -> Deferred<Maybe<[ClientRemoteTabs]>> {
        // Note: this call will get all of the client and tabs data from
        // the application storage tabs store without filter against the
        // BrowserDB client records.
        let deferred = Deferred<Maybe<[ClientRemoteTabs]>>()

        queue.async {
            guard self.isOpen else {
                let error = TabsApiError.UnexpectedTabsError(reason: "Database is closed")
                deferred.fill(Maybe(failure: error as MaybeErrorType))
                return
            }

            if let storage = self.store {
                let records = storage.getAll()
                deferred.fill(Maybe(success: records))
            } else {
                deferred.fill(
                    Maybe(
                        failure: TabsApiError.UnexpectedTabsError(
                            reason: "Unknown error when getting all Rust Tabs"
                        ) as MaybeErrorType
                    )
                )
            }
        }

        return deferred
    }

    public func getClient(fxaDeviceId: String) -> Deferred<Maybe<RemoteClient?>> {
        return self.getAll().bind { result in
            if let failureValue = result.failureValue {
                return deferMaybe(failureValue)
            }

            guard let records = result.successValue else {
                return deferMaybe(nil)
            }

            let client = records.first(where: { $0.clientId == fxaDeviceId })?.toRemoteClient()
            return deferMaybe(client)
        }
    }

    public func getClientGUIDs(completion: @escaping (Set<GUID>?, Error?) -> Void) {
        self.getAll().upon { result in
            if let failureValue = result.failureValue {
                completion(nil, failureValue)
                return
            }
            guard let records = result.successValue else {
                completion(Set<GUID>(), nil)
                return
            }

            let guids = records.map({ $0.clientId })
            completion(Set(guids), nil)
        }
    }

    public func getRemoteClients(remoteDeviceIds: [String]) -> Deferred<Maybe<[ClientAndTabs]>> {
        return self.getAll().bind { result in
            if let failureValue = result.failureValue {
                return deferMaybe(failureValue)
            }
            guard let rustClientAndTabs = result.successValue else {
                return deferMaybe([])
            }

            let clientAndTabs = rustClientAndTabs
                .map { $0.toClientAndTabs() }
                .filter({ record in
                    remoteDeviceIds.contains { deviceId in
                        return record.client.fxaDeviceId != nil &&
                            record.client.fxaDeviceId! == deviceId
                    }
                })
            return deferMaybe(clientAndTabs)
        }
    }

    public func registerWithSyncManager() {
        queue.async { [unowned self] in
           self.store?.registerWithSyncManager()
        }
    }

    // MARK: Remote Command APIs
    public func addRemoteCommand(deviceId: String, url: URL) -> Deferred<Maybe<Bool>> {
        guard let commandQueue = self.commandQueue else {
            let deferred = Deferred<Maybe<Bool>>()
            deferred.fill(Maybe(
                failure: TabsApiError.UnexpectedTabsError(reason: "Command queue is not initialized") as MaybeErrorType
            ))
            return deferred
        }
        return commandQueue.addRemoteCommand(deviceId: deviceId, command: RemoteCommand.closeTab(url: url.absoluteString))
    }

    public func removeRemoteCommand(deviceId: String, url: URL) -> Deferred<Maybe<Bool>> {
        guard let commandQueue = self.commandQueue else {
            let deferred = Deferred<Maybe<Bool>>()
            deferred.fill(Maybe(
                failure: TabsApiError.UnexpectedTabsError(reason: "Command queue is not initialized") as MaybeErrorType
            ))
            return deferred
        }
        return commandQueue.removeRemoteCommand(deviceId: deviceId, command: RemoteCommand.closeTab(url: url.absoluteString))
    }
}

public class RemoteTabsCommandQueue {
    private var commandStore: RemoteCommandStore?

    public init() {}

    public func openCommandStore(tabsStore: TabsStore) {
        self.commandStore = tabsStore.newRemoteCommandStore()
    }

    public func addRemoteCommand(deviceId: String, command: RemoteCommand) -> Deferred<Maybe<Bool>> {
        let deferred = Deferred<Maybe<Bool>>()

        DispatchQueue.global().async {
            guard let commandStore = self.commandStore else {
                deferred.fill(Maybe(failure: TabsApiError.UnexpectedTabsError(reason: "Command store is not initialized") as MaybeErrorType))
                return
            }

            do {
                print("Sending url to command store")
                print(command)
                let result = try commandStore.addRemoteCommand(deviceId: deviceId, command: command)
                deferred.fill(Maybe(success: result))
            } catch {
                deferred.fill(Maybe(failure: error as MaybeErrorType))
            }
        }

        return deferred
    }

    public func removeRemoteCommand(deviceId: String, command: RemoteCommand) -> Deferred<Maybe<Bool>> {
        let deferred = Deferred<Maybe<Bool>>()

        DispatchQueue.global().async {
            guard let commandStore = self.commandStore else {
                deferred.fill(Maybe(failure: TabsApiError.UnexpectedTabsError(reason: "Command store is not initialized") as MaybeErrorType))
                return
            }

            do {
                let result = try commandStore.removeRemoteCommand(deviceId: deviceId, command: command)
                deferred.fill(Maybe(success: result))
            } catch {
                deferred.fill(Maybe(failure: error as MaybeErrorType))
            }
        }

        return deferred
    }
}

public extension RemoteTabRecord {
    func toRemoteTab(client: RemoteClient) -> RemoteTab? {
        guard let url = Foundation.URL(string: self.urlHistory[0], invalidCharacters: false) else { return nil }
        let history = self.urlHistory[1...].map { url in
            Foundation.URL(
                string: url,
                invalidCharacters: false
            )
        }.compactMap { $0 }
        let icon = self.icon != nil ? Foundation.URL(fileURLWithPath: self.icon ?? "") : nil

        return RemoteTab(
            clientGUID: client.guid,
            URL: url,
            title: self.title,
            history: history,
            lastUsed: Timestamp(self.lastUsed),
            icon: icon,
            inactive: self.inactive
        )
    }
}

public extension ClientRemoteTabs {
    func toClientAndTabs(client: RemoteClient) -> ClientAndTabs {
        return ClientAndTabs(
            client: client,
            tabs: self.remoteTabs.map { $0.toRemoteTab(client: client) }.compactMap { $0 })
    }

    func toClientAndTabs() -> ClientAndTabs {
        let client = self.toRemoteClient()
        let tabs = self.remoteTabs.map { $0.toRemoteTab(client: client) }.compactMap { $0 }

        let clientAndTabs = ClientAndTabs(client: client, tabs: tabs)
        return clientAndTabs
    }

    func toRemoteClient() -> RemoteClient {
        let remoteClient = RemoteClient(guid: self.clientId,
                                        name: self.clientName,
                                        modified: UInt64(self.lastModified),
                                        type: "\(self.deviceType)",
                                        formfactor: nil,
                                        os: nil,
                                        version: nil,
                                        fxaDeviceId: self.clientId)
        return remoteClient
    }
}
