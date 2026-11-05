# Moonee

iOS personal-finance app (SwiftUI + SwiftData, iOS 26+, light mode only). Offline-first: data lives on device. **The spec is `docs/FEATURES.md`** — build to it; when code and spec disagree, the spec wins.

## Build & test
```bash
xcodebuild test -project Moonee.xcodeproj -scheme Moonee -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build
```
The project uses file-system synchronized groups: drop a `.swift` file anywhere under `Moonee/` or `MooneeTests/` and it is compiled — never edit `project.pbxproj` to add files. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

## Layout
- `Moonee/App` — `MooneeApp` (container from `Schema.moonee`), `RootView` (the 5 tabs of spec §1: Overview, Budget, Moonee, Watchlist, Account; all but Account are placeholders), `DevSecrets` (Debug + Simulator: loads `OPENROUTER_API_KEY` from the gitignored `.env` into Keychain).
- `Moonee/Core/Models.swift` — data model v2 (spec §11): `Txn` (7 kinds: expense, income, transfer, jarTransfer, lend, borrow, repay; `wallet`/`toWallet`, `jar`/`toJar`, `debt`, `splits`), `IncomeSplit`, `Category`, `Wallet` (cash/bank/ewallet/credit), `Jar` (envelope), `Recurring`, `Goal`, `Debt`, `Asset` (manual quantity × unit price), `MerchantRule`, `Schema.moonee`, first-launch `Seed`. Enums are stored as `…Raw` strings with typed accessors (`kind`, `type`, …) so `#Predicate` works. Default jars/categories are stored by `key` (`jar.essentials`, `category.food`) and shown via `.name` (String Catalog); a user-chosen name goes in `customName`. CloudKit-ready: defaults/optionals everywhere, optional to-many relationships with inverses, no unique constraints — `CloudKitSchemaTests` enforces it.
- `Moonee/Core/Money.swift` — every amount is a positive `Int` in minor units + a `currencyCode`. `Money(minor, code).formatted()` (FormatStyle), `Money(major:)`, `Money.defaultCurrency` (UserDefaults `money.currency` override, else `Locale.current.currency`).
- `Moonee/Core/Ledger.swift` — all money math, pure Swift: wallet balances (credit cards go negative), jar balances with carry-over, per-income split by % or stored `IncomeSplit`s, jar transfers, debt remaining, `jarMonth` (jar card: balance, spent / (start of month + added this month)), net worth. `Ledger(txns:wallets:jars:)` adapts SwiftData models. Never compute balances in views.
- `Moonee/Core/Theme.swift` — colors (`.mooneeGreen`, `.mooneeDark`, `.mooneeInk`, `.mooneeYellow`), `MooneeBackground`, `.card()`, `.mooneeScreen(title)`, `IconBadge`, `PillPicker`, `MooneeButtonStyle`, `Hills`. Reuse these; match the mockup look (mint glass cards, green pill buttons).
- `Moonee/Core/SpendingSummary.swift` — pure expense totals per week/month/year vs the previous period.
- `Moonee/Localizable.xcstrings` / `InfoPlist.xcstrings` — English source + Vietnamese. Write UI text in English (`Text("Wallets")`); add the `vi` translation. Default jar/category keys are manual entries there.
- `Moonee/Features/AI` — `LLM` protocol with Apple Foundation Models and an OpenAI-compatible BYOK client (key in Keychain), `Classifier` (category prompt + strict JSON validation), `AISettingsView`.
- `Moonee/Features/QuickInput` — engines only, no screen: `QuickParser` (rule-based Vietnamese parser = the spec's fallback parser), `ReceiptScanner` (Vision OCR), `SpeechInput` (vi-VN dictation).
- `Moonee/Features/Import/StatementCSV.swift` — bank statement CSV parsing → `ImportDraft`.
- `Moonee/Features/{Account,Wallets,Jars}` — settings screens reached from the Account tab: categories, wallets, jar percents, category → jar mapping.

## Known gaps vs the spec (fix before building on them)
- iCloud sync is not switched on: no iCloud capability/entitlements yet (needs the team; S11). The schema is ready.
- Ledger sums every currency as-is (no FX). Fine while all wallets use the default currency.
- No settings UI for the currency override (`money.currency`) or language yet (S7).
- `Features/AI` strings (`AISettingsView`, LLM errors) are still hard-coded Vietnamese, and `QuickParser` matches Vietnamese category names instead of `category.*` keys (S3).
- `SpeechInput` is fixed to vi-VN; `QuickParser` knows Vietnamese only.
- Schema v2 has no migration from v1: delete the app from the simulator if it fails to launch with an old store.

## Conventions
- Add new `@Model` types in your feature folder and register them in `Schema.mooneeModels` (Models.swift). Keep them CloudKit-ready (defaults/optionals, optional relationships with inverses, no `.unique`).
- Money: store minor units + `currencyCode`, format with `Money.formatted()`, compute with `Ledger`. Never `"\(amount)đ"`.
- UI text goes through the String Catalog (English key + `vi`); store keys, not translated text.
- Secrets (API keys) go in Keychain, never SwiftData/UserDefaults.
- All money numbers are computed in Swift; the LLM only explains them (spec §9.3).
- Keep it small: native frameworks first (Speech, Vision, URLSession), add a Swift package only when a framework can't do it.
