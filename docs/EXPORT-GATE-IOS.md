# Export gate (iOS): what the owner must create in App Store Connect

Owner order 2026-11-17: everything a person takes out of Aperta (Save to Photos and Share, from the editor and every tool) uses one export. Editing, previews and all tool screens up to the export step stay free.

## How it works in the app

| Situation | What happens |
|---|---|
| Premium active | Save or Share goes ahead, nothing is used up. |
| Exports left from an export pack | Save or Share goes ahead, one export is used up. |
| Neither | The paywall sheet opens: 3 exports, Premium, Restore purchases. After a purchase the action the person asked for continues by itself. |
| App Store not reachable | The sheet says prices are not available and offers Try again. Nothing is unlocked, nothing is charged. |

Aperta has no rewarded ads, so there is no video option. The existing banner and interstitial placements are unchanged (the interstitial now follows a finished save or a completed share).

- One tap on **Save to Photos** or **Share** is one export, however many photos it covers (a compressed or converted batch, a collage, a passport sheet are each one export).
- An export is used up only after the photos are really in the library (the Photos change finished without an error), or the share sheet reported a completed destination. Cancelling the share sheet, denying Photos access or a save error use nothing (`ExportStore.settle`).
- A purchase adds exports only after StoreKit verified it. Pending (Ask to Buy), cancelled, failed and unverified purchases add nothing. The transaction is saved before it is finished, and each transaction id is applied once. A refund takes the 3 exports back once, never below zero.
- Exports from packs are kept in the Keychain (with a UserDefaults copy), so they survive deleting and reinstalling the app.
- Premium comes from `Transaction.currentEntitlements`, refreshed at launch, after a purchase and on Restore purchases (paywall and Settings). Used-up packs cannot be restored (consumables).
- Price text always comes from StoreKit (`displayPrice`). There is no price in code.
- Code: `Sources/Purchases` (StoreKit 2, pure logic, storage, paywall sheet), `Sources/Features/ExportBar.swift` (every tool and the editor export), `CnvPDFShareButton` in `ConvertView.swift` (Photos to PDF share), Settings rows "Your exports" and "Restore purchases". Unit tests: `Tests/ExportEntitlementTests.swift`.

### Paths that are gated

- Editor export sheet: Save to Photos, Share.
- Collage, Compress, Resize, Convert (photos), Watermark, Passport photo, Photo details: Save to Photos, Share (all use `ExportBar`).
- Convert to PDF: Share PDF.

There is no other way out of the app (no clipboard copy, no Files export, no drag out).

## Products to create (App Store Connect > the app > Monetization > In-App Purchases)

Product ids must match exactly. The same ids are used in CareerKit; ids are per app, so there is no clash.

### 1. Export pack

| Field | Value |
|---|---|
| Type | Consumable |
| Reference Name | Export Pack 3 |
| Product ID | `export_pack_3` |
| Price | USD 0.99 (price point "Tier 1", base country United States, let Apple convert the rest) |
| Display Name (en-U.S., up to 30 characters) | 3 Exports |
| Description (en-U.S., up to 45 characters) | Save or share your photos 3 times |

### 2. Premium

| Field | Value |
|---|---|
| Type | Non-Consumable |
| Reference Name | Premium Unlimited Exports |
| Product ID | `premium_unlimited` |
| Price | Your choice. Suggested USD 9.99 (the app shows whatever you set, so it can be changed later without a build). |
| Display Name (en-U.S.) | Premium |
| Description (en-U.S.) | Unlimited exports, one purchase |
| Family Sharing | Optional. Off is fine. |

### For both products

- **Review screenshot** (required): use the CI screenshot `paywall.png` (artifact `screenshots` of the latest green run; sample prices in it are test values and are not shipped).
- **Review notes**: "Open any tool, pick a photo, tap Save to Photos. The sheet offers 3 exports and Premium. Purchases use the sandbox. Restore purchases is on the sheet and in Settings."
- Both products need status **Ready to Submit**. Aperta has no submitted version yet, so attach both to the first version on the version page ("In-App Purchases and Subscriptions").

## What remains for the owner

1. **Paid Apps Agreement, bank account and tax forms** in App Store Connect. Required before in-app purchases can be sold or reviewed.
2. The App Store Connect record, bundle id, production AdMob ids, store listing and the rest of the Aperta launch list are still open (see the Aperta notes); this change did not touch them.
3. Create the two products above and attach them to the first version.
4. Test with a sandbox Apple Account on TestFlight: buy 3 exports, cancel the share sheet (count must stay), deny Photos access (count must stay), finish a save (count drops by 1), buy Premium, delete and reinstall, tap Restore purchases, test Ask to Buy and a refund if possible. None of this could be run here (no Mac, no device); CI only compiles, runs unit tests and takes simulator screenshots.
5. Store copy: say in the description that saving and sharing use an export (a pack or Premium), editing is free. Do not say "completely free" or "costs nothing". Settings and the welcome screen already say this. Privacy answers: no change expected (purchases are handled by Apple; the app keeps no purchase history).
6. Decide the Premium price. Premium does not remove ads (banner and interstitial stay, as ordered).
7. In-app text is English only (the app has no localization yet), so the new strings are English only.
