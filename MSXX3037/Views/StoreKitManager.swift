// StoreKitManager.swift
// EMuSX アプリ内課金管理 (StoreKit 2)

import StoreKit
import SwiftUI
import Combine

@MainActor
final class StoreKitManager: ObservableObject {

    // MARK: - Singleton
    static let shared = StoreKitManager()

    // MARK: - Constants
    static let productID = "Unlock.emusx"
    private static let premiumKey = "premium_unlocked"

    // MARK: - Published State
    @Published private(set) var isPremium: Bool
    @Published private(set) var product: Product?
    @Published var purchaseState: PurchaseState = .idle

    enum PurchaseState: Equatable {
        case idle
        case loading
        case purchasing
        case restoring
        case success
        case failed(String)
    }

    // MARK: - Private
    private var transactionUpdates: Task<Void, Never>?

    // MARK: - Init
    private init() {
        // キャッシュからオフライン時の状態を復元
        isPremium = UserDefaults.standard.bool(forKey: Self.premiumKey)

        // トランザクション更新を監視
        transactionUpdates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(transactionResult: result)
            }
        }

        // 製品情報を非同期取得
        Task { await self.loadProduct() }
        // エンタイトルメントを検証
        Task { await self.refreshEntitlements() }
    }

    deinit {
        transactionUpdates?.cancel()
    }

    // MARK: - Load Product
    func loadProduct() async {
        purchaseState = .loading
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
            purchaseState = .idle
        } catch {
            print("[StoreKit] loadProduct error: \(error)")
            purchaseState = .idle
        }
    }

    // MARK: - Purchase
    func purchase() async {
        guard let product = product else {
            purchaseState = .failed("製品情報を取得中です。しばらくお待ちください。")
            return
        }
        purchaseState = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(transactionResult: verification)
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore
    func restore() async {
        purchaseState = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if isPremium {
                purchaseState = .success
            } else {
                purchaseState = .failed("復元できる購入履歴が見つかりませんでした。")
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Refresh Entitlements
    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               tx.productID == Self.productID,
               tx.revocationDate == nil {
                unlock()
                return
            }
        }
        // ネットワーク不達時はキャッシュを保持（再ロック不要）
    }

    // MARK: - Private Helpers
    private func handle(transactionResult: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let tx) = transactionResult else { return }
        if tx.productID == Self.productID && tx.revocationDate == nil {
            unlock()
            purchaseState = .success
        }
        await tx.finish()
    }

    private func unlock() {
        isPremium = true
        UserDefaults.standard.set(true, forKey: Self.premiumKey)
    }
}
