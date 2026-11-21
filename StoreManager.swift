import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let sevenDayProductID = "com.piancaishike.ios.seven_day_access"
    static let monthlyProductID = "com.piancaishike.ios.monthly_premium"
    static let sevenDaysSeconds: TimeInterval = 7 * 24 * 60 * 60

    @Published var sevenDayProduct: Product?
    @Published var monthlyProduct: Product?
    @Published var currentPlan: String = "free"
    @Published var planUpdatedAtMs: Double = 0

    private var updatesTask: Task<Void, Never>?
    weak var webDelegate: WebBillingDelegate?

    private let defaults = UserDefaults.standard
    private let keySevenDayStart = "sevenDayPurchasedAtMs"

    init() {
        updatesTask = listenForTransactions()
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [
                Self.sevenDayProductID,
                Self.monthlyProductID
            ])
            for product in products {
                if product.id == Self.sevenDayProductID {
                    sevenDayProduct = product
                } else if product.id == Self.monthlyProductID {
                    monthlyProduct = product
                }
            }
            webDelegate?.didUpdatePrices(
                sevenDay: sevenDayProduct?.displayPrice ?? "HK$8",
                monthly: monthlyProduct?.displayPrice ?? "HK$25"
            )
        } catch {
            webDelegate?.didUpdatePrices(sevenDay: "HK$8", monthly: "HK$25")
        }
    }

    func refreshEntitlements() async {
        var hasMonthly = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == Self.monthlyProductID && transaction.revocationDate == nil {
                    hasMonthly = true
                }
            }
        }

        if hasMonthly {
            currentPlan = "monthly"
            planUpdatedAtMs = Date().timeIntervalSince1970 * 1000
        } else {
            let savedStartMs = defaults.double(forKey: keySevenDayStart)
            let nowMs = Date().timeIntervalSince1970 * 1000
            if savedStartMs > 0 && (nowMs - savedStartMs) < (Self.sevenDaysSeconds * 1000) {
                currentPlan = "seven_day"
                planUpdatedAtMs = savedStartMs
            } else {
                if savedStartMs > 0 {
                    defaults.removeObject(forKey: keySevenDayStart)
                }
                currentPlan = "free"
                planUpdatedAtMs = nowMs
            }
        }

        webDelegate?.didUpdateMembership(plan: currentPlan, updatedAtMs: planUpdatedAtMs)
    }

    func purchaseSevenDay() async {
        if sevenDayProduct == nil { await loadProducts() }
        guard let product = sevenDayProduct else {
            webDelegate?.didReceiveNotice(title: "未能載入方案", message: "暫時無法取得 App Store 商品資訊，請稍後再試。")
            return
        }
        await performPurchase(product)
    }

    func purchaseMonthly() async {
        if monthlyProduct == nil { await loadProducts() }
        guard let product = monthlyProduct else {
            webDelegate?.didReceiveNotice(title: "未能載入方案", message: "暫時無法取得 App Store 訂閱資訊，請稍後再試。")
            return
        }
        await performPurchase(product)
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if currentPlan == "monthly" {
                webDelegate?.didReceiveNotice(title: "已恢復購買", message: "您的月費會員資格已恢復。")
            } else if currentPlan == "seven_day" {
                webDelegate?.didReceiveNotice(title: "已恢復狀態", message: "您的七日體驗方案仍在有效期間內。")
            } else {
                webDelegate?.didReceiveNotice(title: "未發現有效訂閱", message: "目前未找到有效中的月費會員訂閱。")
            }
        } catch {
            webDelegate?.didReceiveNotice(title: "恢復失敗", message: "無法連線至 App Store，請稍後再試。")
        }
    }

    private func performPurchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                if transaction.productID == Self.sevenDayProductID {
                    let nowMs = Date().timeIntervalSince1970 * 1000
                    defaults.set(nowMs, forKey: keySevenDayStart)
                }
                await transaction.finish()
                await refreshEntitlements()
                webDelegate?.didReceiveNotice(title: "解鎖成功", message: "感謝您的支持，方案權限已即時生效。")
            case .userCancelled:
                break
            case .pending:
                webDelegate?.didReceiveNotice(title: "交易待處理", message: "您的購買正在等待 App Store 確認。")
            @unknown default:
                break
            }
        } catch {
            webDelegate?.didReceiveNotice(title: "購買未完成", message: "交易未能完成，請稍後再試。")
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if case .verified(let transaction) = result {
                    if transaction.productID == Self.sevenDayProductID {
                        let nowMs = Date().timeIntervalSince1970 * 1000
                        await MainActor.run {
                            self.defaults.set(nowMs, forKey: self.keySevenDayStart)
                        }
                    }
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    enum StoreError: Error {
        case failedVerification
    }
}

@MainActor
protocol WebBillingDelegate: AnyObject {
    func didUpdatePrices(sevenDay: String, monthly: String)
    func didUpdateMembership(plan: String, updatedAtMs: Double)
    func didReceiveNotice(title: String, message: String)
}
