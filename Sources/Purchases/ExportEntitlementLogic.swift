import Foundation

/// Store product ids. They must match App Store Connect exactly (see docs/EXPORT-GATE-IOS.md).
enum ExportProduct {
    /// Consumable. One purchase adds `packSize` exports.
    static let pack3 = "export_pack_3"
    /// Non-consumable. Unlimited exports.
    static let premium = "premium_unlimited"
    /// Exports added by one pack.
    static let packSize = 3
    static let all: [String] = [pack3, premium]
}

/// What lets an export go ahead right now.
enum ExportAccess: Equatable {
    /// Premium: unlimited exports, nothing is used up.
    case premium
    /// One export earned by watching a rewarded ad to the end. Used before pack exports.
    case adGrant
    /// One of the exports from an export pack.
    case credit
    /// Nothing available: the paywall is shown.
    case locked

    var isOpen: Bool { self != .locked }
}

/// What a finished export used up.
enum ExportSpend: Equatable {
    case nothing
    case adGrant
    case credit
}

/// How an export attempt ended, as reported by the system (Photos save finished, share sheet completed).
enum ExportOutcome: Equatable {
    case completed
    case cancelled
    case failed
}

/// The rules for export credits and Premium, with no storage, no StoreKit and no UI, so they can be unit tested.
///
/// A credit is spent only by `recordCompletedExport`, which the export bar calls after the photo was really saved
/// to the library or the share sheet reported that the file was really shared. Cancelling or failing never calls it.
/// A store transaction is applied once, however many times StoreKit delivers it.
struct ExportEntitlementLogic: Equatable, Codable {
    /// Exports left from purchased packs.
    private(set) var credits: Int
    /// Last verified Premium state. Refreshed from StoreKit at launch and after every purchase or restore.
    private(set) var isPremium: Bool
    /// Transactions that were already looked at, so a redelivered one never adds exports twice.
    private(set) var handledTransactionIDs: [UInt64]
    /// Transactions that were refunded, so a refund takes exports back once.
    private(set) var revokedTransactionIDs: [UInt64]

    /// Bounds on the stored lists. Far above anything a real device sees.
    static let maxRemembered = 500
    static let maxCredits = 100_000

    init(credits: Int = 0, isPremium: Bool = false, handledTransactionIDs: [UInt64] = [], revokedTransactionIDs: [UInt64] = []) {
        self.credits = max(0, credits)
        self.isPremium = isPremium
        self.handledTransactionIDs = handledTransactionIDs
        self.revokedTransactionIDs = revokedTransactionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case credits, isPremium, handledTransactionIDs, revokedTransactionIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            credits: try container.decodeIfPresent(Int.self, forKey: .credits) ?? 0,
            isPremium: try container.decodeIfPresent(Bool.self, forKey: .isPremium) ?? false,
            handledTransactionIDs: try container.decodeIfPresent([UInt64].self, forKey: .handledTransactionIDs) ?? [],
            revokedTransactionIDs: try container.decodeIfPresent([UInt64].self, forKey: .revokedTransactionIDs) ?? []
        )
    }

    // MARK: Access

    static func resolve(isPremium: Bool, credits: Int, hasAdGrant: Bool = false) -> ExportAccess {
        if isPremium { return .premium }
        if hasAdGrant { return .adGrant }
        if credits > 0 { return .credit }
        return .locked
    }

    func access(hasAdGrant: Bool = false) -> ExportAccess {
        Self.resolve(isPremium: isPremium, credits: credits, hasAdGrant: hasAdGrant)
    }

    // MARK: Purchases

    /// Adds the exports of one pack. Returns false when this transaction was already applied.
    @discardableResult
    mutating func applyPurchase(transactionID: UInt64, exports: Int = ExportProduct.packSize) -> Bool {
        guard !handledTransactionIDs.contains(transactionID) else { return false }
        remember(handled: transactionID)
        credits = min(Self.maxCredits, credits + max(0, exports))
        return true
    }

    /// Takes the exports of a refunded pack back, never below zero. Applies once per transaction.
    /// A pack that was refunded before it was ever applied is marked as handled and adds nothing.
    mutating func applyRevocation(transactionID: UInt64, exports: Int = ExportProduct.packSize) {
        guard !revokedTransactionIDs.contains(transactionID) else { return }
        revokedTransactionIDs.append(transactionID)
        if revokedTransactionIDs.count > Self.maxRemembered {
            revokedTransactionIDs.removeFirst(revokedTransactionIDs.count - Self.maxRemembered)
        }
        if handledTransactionIDs.contains(transactionID) {
            credits = max(0, credits - max(0, exports))
        } else {
            remember(handled: transactionID)
        }
    }

    mutating func setPremium(_ value: Bool) {
        isPremium = value
    }

    // MARK: Spending

    /// Called only after an export really finished. Premium uses nothing, then an ad export is used, otherwise one
    /// export from a pack. The ad grant itself lives in `ExportStore` (it is not purchased and not stored).
    @discardableResult
    mutating func recordCompletedExport(hasAdGrant: Bool = false) -> ExportSpend {
        if isPremium { return .nothing }
        if hasAdGrant { return .adGrant }
        if credits > 0 {
            credits -= 1
            return .credit
        }
        return .nothing
    }

    private mutating func remember(handled id: UInt64) {
        handledTransactionIDs.append(id)
        if handledTransactionIDs.count > Self.maxRemembered {
            handledTransactionIDs.removeFirst(handledTransactionIDs.count - Self.maxRemembered)
        }
    }

    // MARK: Persistence helpers

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Never throws: missing or corrupt data means "nothing purchased yet".
    static func decoded(from data: Data?) -> ExportEntitlementLogic {
        guard let data = data, let value = try? JSONDecoder().decode(ExportEntitlementLogic.self, from: data) else {
            return ExportEntitlementLogic()
        }
        return value
    }
}
