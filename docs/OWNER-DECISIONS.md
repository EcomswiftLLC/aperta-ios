# Owner decisions for Aperta (read before changing monetisation)

**2026-11-17, from the owner in chat: Aperta stays FREE. No in-app purchases, no export packs, no Premium, no StoreKit.**
Each export (Save to Photos, Share, Share PDF) is paid for with one opt-in AdMob rewarded ad ("Watch a short ad to export").
**If no ad is available, the export is simply free.** This is implemented in `Sources/Ads/RewardedGate.swift`.

This overrides the 2026-11-14 "export gate for all apps" order for Aperta only. Do not re-add `Sources/Purchases`,
`ExportStore`, paywall sheets or restore-purchases rows. If you believe this is wrong, ask the owner; do not restore it silently.
(The gate was restored once by another session and reverted again on 2026-11-17.)
