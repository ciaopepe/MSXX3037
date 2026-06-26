// iCloudSyncManager.swift
// セーブデータ（iCloud Drive）と設定（NSUbiquitousKeyValueStore）の同期管理

import Foundation
import Combine

@MainActor
final class iCloudSyncManager: ObservableObject {
    static let shared = iCloudSyncManager()

    // MARK: - Public State

    /// iCloud Drive が利用可能か（サインイン済み）
    @Published private(set) var isAvailable: Bool = false

    /// ユーザーが iCloud Sync を有効にしているか
    @Published var isSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSyncEnabled, forKey: Self.syncEnabledKey)
            if isSyncEnabled { Task { await startSync() } }
        }
    }

    /// セーブデータ保存先 URL（同期ON→iCloud Drive、OFF→ローカル）
    var effectiveSaveBaseURL: URL {
        if isSyncEnabled, let cloud = cloudContainerURL {
            return cloud.appendingPathComponent("SaveStates", isDirectory: true)
        }
        return localSaveBaseURL
    }

    // MARK: - Private

    private static let syncEnabledKey = "iCloudSyncEnabled"
    nonisolated static let containerID = "iCloud.IOV3037.EMuSX"

    /// iCloud Drive コンテナ URL（非同期で取得）
    private var cloudContainerURL: URL?

    private let localSaveBaseURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    private var kvStore: NSUbiquitousKeyValueStore { .default }

    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        isSyncEnabled = UserDefaults.standard.bool(forKey: Self.syncEnabledKey)
        checkAvailability()

        // iCloud アカウント変更を監視
        let token = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAvailability() }
        }
        notificationTokens.append(token)

        // KV Store 外部変更を監視
        let kvToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] notification in
            // Notification は非 Sendable なので、必要な値だけ Sendable な型で取り出して Task に渡す
            let changedKeys = notification.userInfo?[
                NSUbiquitousKeyValueStoreChangedKeysKey
            ] as? [String] ?? []
            Task { @MainActor [weak self] in self?.handleKVStoreChange(changedKeys) }
        }
        notificationTokens.append(kvToken)

        kvStore.synchronize()

        if isSyncEnabled {
            Task { await startSync() }
        }
    }

    // MARK: - Availability

    private func checkAvailability() {
        isAvailable = FileManager.default.ubiquityIdentityToken != nil
        if isAvailable {
            Task.detached(priority: .background) {
                let url = FileManager.default.url(
                    forUbiquityContainerIdentifier: Self.containerID
                )
                await MainActor.run {
                    self.cloudContainerURL = url
                }
            }
        } else {
            cloudContainerURL = nil
        }
    }

    // MARK: - Sync Start

    private func startSync() async {
        guard isAvailable else { return }

        // コンテナ URL が未取得なら待機（最大 5 秒）
        if cloudContainerURL == nil {
            await resolveContainerURL()
        }

        guard let cloudBase = cloudContainerURL else { return }
        let saveDir = cloudBase.appendingPathComponent("SaveStates", isDirectory: true)
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        // ローカル → iCloud マイグレーション
        await migrateLocalToCloud(cloudSaveDir: saveDir)
    }

    private func resolveContainerURL() async {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let url = FileManager.default.url(
                    forUbiquityContainerIdentifier: Self.containerID
                )
                await MainActor.run {
                    self.cloudContainerURL = url
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Migration: Local → iCloud

    private func migrateLocalToCloud(cloudSaveDir: URL) async {
        let fm = FileManager.default
        let extensions = ["sav", "png"]
        for ext in extensions {
            guard let files = try? fm.contentsOfDirectory(
                at: localSaveBaseURL,
                includingPropertiesForKeys: nil
            ).filter({ $0.pathExtension == ext }) else { continue }

            for local in files {
                let dst = cloudSaveDir.appendingPathComponent(local.lastPathComponent)
                guard !fm.fileExists(atPath: dst.path) else { continue }
                try? fm.copyItem(at: local, to: dst)
            }
        }
    }

    // MARK: - File Download Helper

    /// iCloud ファイルが未ダウンロードなら DL をトリガし、完了まで待機（最大 10 秒）
    func ensureDownloaded(url: URL) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        // ダウンロード状態確認
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        if let status = attrs?[.init("NSURLUbiquitousItemDownloadingStatusKey")] as? String,
           status == "NSURLUbiquitousItemDownloadingStatusCurrent" {
            return
        }

        try? fm.startDownloadingUbiquitousItem(at: url)
        await waitForDownload(url: url)
    }

    private func waitForDownload(url: URL, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let status = attrs?[.init("NSURLUbiquitousItemDownloadingStatusKey")] as? String,
               status == "NSURLUbiquitousItemDownloadingStatusCurrent" {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
    }

    // MARK: - Settings Sync (NSUbiquitousKeyValueStore)

    /// 設定を KV Store へ書き出し（Push）
    func pushSettings(_ settings: [String: Any]) {
        for (key, value) in settings {
            kvStore.set(value, forKey: key)
        }
        kvStore.synchronize()
    }

    /// KV Store から設定を読み込んで UserDefaults へ反映
    func pullSettings(keys: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            if let v = kvStore.object(forKey: key) {
                result[key] = v
                UserDefaults.standard.set(v, forKey: key)
            }
        }
        return result
    }

    private func handleKVStoreChange(_ changedKeys: [String]) {
        guard !changedKeys.isEmpty else { return }

        for key in changedKeys {
            if let v = kvStore.object(forKey: key) {
                UserDefaults.standard.set(v, forKey: key)
            }
        }
        // 設定変更をアプリへ通知
        NotificationCenter.default.post(
            name: .iCloudSettingsDidChange,
            object: nil,
            userInfo: ["keys": changedKeys]
        )
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let iCloudSettingsDidChange = Notification.Name("iCloudSettingsDidChange")
}
