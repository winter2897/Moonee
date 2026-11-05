# Moonee

iOS personal-finance app (SwiftUI + SwiftData, iOS 18+). Offline-first: data lives on device. **The spec is `docs/FEATURES.md`** — build to it; when code and spec disagree, the spec wins.

## Build & test
```bash
xcodebuild test -project Moonee.xcodeproj -scheme Moonee -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build
```
The project uses file-system synchronized groups: drop a `.swift` file anywhere under `Moonee/` or `MooneeTests/` and it is compiled — never edit `project.pbxproj` to add files. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

## Layout
- `Moonee/App` — `MooneeApp` (ModelContainer schema list), `RootView` (the 5 tabs of spec §1: Tổng quan, Ngân sách, Moonee, Quan tâm, Tài khoản; all but Tài khoản are placeholders), `DevSecrets` (Debug + Simulator: loads `OPENROUTER_API_KEY` from the gitignored `.env` into Keychain).
- `Moonee/Core/Models.swift` — `Txn`, `Category`, `Wallet`, `Jar` + first-launch `Seed`. `Txn.amount` is a positive `Int` VND; `kind` (.expense/.income) gives the sign. `Txn.source` records origin; `rawInput` keeps the original text for AI. Wallet balance is computed from its txns.
- `Moonee/Core/Theme.swift` — colors (`.mooneeGreen`, `.mooneeDark`, `.mooneeInk`, `.mooneeYellow`), `Int.vnd` ("250.000 đ"), `MooneeBackground`, `.card()`, `.mooneeScreen(title)`, `IconBadge`, `PillPicker`, `MooneeButtonStyle`, `Hills`. Reuse these; match the mockup look (mint glass cards, green pill buttons).
- `Moonee/Core/SpendingSummary.swift` — pure expense totals per week/month/year vs the previous period.
- `Moonee/Features/AI` — `LLM` protocol with Apple Foundation Models and an OpenAI-compatible BYOK client (key in Keychain), `Classifier` (category prompt + strict JSON validation), `AISettingsView`.
- `Moonee/Features/QuickInput` — engines only, no screen: `QuickParser` (rule-based Vietnamese parser = the spec's fallback parser), `ReceiptScanner` (Vision OCR), `SpeechInput` (vi-VN dictation).
- `Moonee/Features/Import/StatementCSV.swift` — bank statement CSV parsing → `ImportDraft`.
- `Moonee/Features/{Account,Wallets,Jars}` — settings screens reached from the Tài khoản tab: categories, wallets, jar percents, category → jar mapping.

## Known gaps vs the spec (fix before building on them)
- Models: no currency (VND `Int` only), only expense/income kinds (no transfer, jar transfer, lend/borrow, card payment), jars hold a percent but no balance (spec §4.1 is envelope with carry-over and per-income split), default jars/categories stored by name instead of key (spec §10.3), not CloudKit-ready (needs defaults/optionals).
- UI strings are hard-coded Vietnamese; spec wants String Catalog with English default + Vietnamese.
- `SpeechInput` is fixed to vi-VN; `QuickParser` knows Vietnamese only.

## Conventions
- Add new `@Model` types in your feature folder and register them in the `ModelContainer(for:)` list in `MooneeApp.swift`.
- Secrets (API keys) go in Keychain, never SwiftData/UserDefaults.
- All money numbers are computed in Swift; the LLM only explains them (spec §9.3).
- Keep it small: native frameworks first (Speech, Vision, URLSession), add a Swift package only when a framework can't do it.
