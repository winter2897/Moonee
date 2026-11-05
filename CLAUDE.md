# Moonee

iOS personal-finance app (SwiftUI + SwiftData, iOS 26+, light mode only). Offline-first: data lives on device. **The spec is `docs/FEATURES.md`** — build to it; when code and spec disagree, the spec wins.

## Build & test
```bash
xcodebuild test -project Moonee.xcodeproj -scheme Moonee -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build
```
The project uses file-system synchronized groups: drop a `.swift` file anywhere under `Moonee/` or `MooneeTests/` and it is compiled — never edit `project.pbxproj` to add files. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
MLX compiles Metal shaders: a fresh machine needs `xcodebuild -downloadComponent MetalToolchain` once. MLX cannot run in the Simulator; the local-model eval runs on the Mac (`tools/ParseEval/run.sh`).

## Layout
- `Moonee/App` — `MooneeApp` (container from `Schema.moonee`), `RootView` (5 tabs of spec §1 with `MooneeTabBar`; (+) selects the Moonee chat tab; injects `\.balanceHidden`), `Prefs` (shared UserDefaults keys: hide balances, profile name/avatar, reminder level), `DevSecrets` (Debug + Simulator: loads `OPENROUTER_API_KEY` from the gitignored `.env` into Keychain).
- Tab roots, one file per feature so nobody edits `RootView`: `Features/Overview/OverviewView`, `Features/Budget/BudgetView`, `Features/Chat/ChatView`, `Features/Watchlist/WatchlistView`, `Features/Account/AccountView`.
- `Moonee/Core/Models.swift` — data model v2 (spec §11): `Txn` (7 kinds: expense, income, transfer, jarTransfer, lend, borrow, repay; `wallet`/`toWallet`, `jar`/`toJar`, `debt`, `splits`), `IncomeSplit`, `Category`, `Wallet` (cash/bank/ewallet/credit), `Jar` (envelope), `Recurring`, `Goal`, `Debt`, `Asset` (manual quantity × unit price), `MerchantRule`, `Schema.moonee`, first-launch `Seed`. Enums are stored as `…Raw` strings with typed accessors (`kind`, `type`, …) so `#Predicate` works. Default jars/categories are stored by `key` (`jar.essentials`, `category.food`) and shown via `.name` (String Catalog); a user-chosen name goes in `customName`. CloudKit-ready: defaults/optionals everywhere, optional to-many relationships with inverses, no unique constraints — `CloudKitSchemaTests` enforces it.
- `Moonee/Core/Money.swift` — every amount is a positive `Int` in minor units + a `currencyCode`. `Money(minor, code).formatted()` (FormatStyle), `Money(major:)`, `Money.defaultCurrency` (UserDefaults `money.currency` override, else `Locale.current.currency`).
- `Moonee/Core/Ledger.swift` — all money math, pure Swift: wallet balances (credit cards go negative), jar balances with carry-over from stored `IncomeSplit`s and pinned expense jars, jar transfers, debt remaining, `jarMonth` (jar card: balance, spent / (start of month + added this month)), net worth. `Ledger(txns:wallets:jars:)` adapts SwiftData models. Never compute balances in views.
- `Moonee/Core/Theme.swift` — colors (`.mooneeGreen`, `.mooneeDark`, `.mooneeInk`, `.mooneeYellow`), `MooneeBackground`, `.card()`, `.mooneeScreen(title)`, `IconBadge`, `PillPicker`, `MooneeButtonStyle`, `Hills`. Reuse these; match the mockup look (mint glass cards, green pill buttons).
- `Moonee/Core/SpendingSummary.swift` — pure expense totals per week/month/year vs the previous period.
- `Moonee/Localizable.xcstrings` / `InfoPlist.xcstrings` — English source + Vietnamese. Write UI text in English (`Text("Wallets")`); add the `vi` translation. Default jar/category keys are manual entries there.
- `Moonee/Features/AI` — the AI engine, no UI. `Assistant` (entry point: `handle(text, history:, context:)` → transactions / answer / facts), `AIRouter` (spec §9.1 modes), `LLM` protocol with `AppleLLM` (Foundation Models, `@Generable`) and BYOK `OpenAICompatibleLLM` / `AnthropicLLM` / `GeminiLLM` (keys in Keychain), `AITool` + `MooneeTools` (Swift tools over the `LedgerReading` protocol), `Skill` (routing + per-language instruction files), `Classifier`, `AISettingsView`. Local open models (spec §9.2): `LocalModel.catalog` (pinned Hugging Face MLX repos, RAM recommendation), `LocalModelStore` / `LocalModelDownloads` (resumable, Wi-Fi-only downloads to Application Support/Models), `LocalLLM` (MLX Swift; JSON-schema-constrained parsing via MLXGuidedGeneration; `LocalRuntime` loads on use, unloads on background), `LocalModelsView` (catalog screen, strings in `LocalModels.xcstrings`).
- `Moonee/Features/QuickInput` — engines only, no screen: `QuickParser` (rule parser for every language in `Lexicon.all`: 7 kinds, several per message, currency-aware, returns plain `ParsedTxn`), `ReceiptScanner` (Vision OCR), `SpeechInput` (vi-VN dictation).
- `Moonee/Resources/Locales/<lang>/` — per-language parse dictionary (`Lexicon+<lang>.swift`), persona `moonee.<lang>.md` and skill files `<skill>.<lang>.md` (full part, then `<!-- short -->` part for small models). File names must be unique: the bundle is flat.
- `Moonee/Core/StoreLedger.swift` — `StoreLedger(context)`: the SwiftData books as `LedgerReading` (snapshot, for `MooneeTools`/any screen); `ParserContext(context)` (wallets, jar/category names, merchant rules); `Category/Jar.parserKey` (key, or `*.custom.<name>` for user-made ones).
- `Moonee/Features/Chat` — the Moonee tab: `ChatView` (calls `Assistant.handle`), `ChatBook` (ParsedTxn → `Txn` save + `allocate`, undo (also drops a debt it emptied), asks back for a missing amount, transfer wallet or jar (`Lookup.unresolved` + `fill`), receipt OCR → expense, tool facts → text), `ChatMessage` (@Model, chat history; `txns` ↔ `Txn.chatMessage`), `TxnEditForm` lives in `Features/Transactions` (shared with the ledger).
- `Moonee/Features/Import/StatementCSV.swift` — bank statement CSV parsing → `ImportDraft`.
- `Moonee/Features/Budget` — Budget tab (spec §4.1–4.3): `BudgetView` (3 segments) + `JarsSection` (jar cards, jar detail, `JarTransferSheet`), `BillsSection` (`RecurringForm`, "Paid"), `BudgetActions` (every Budget write: `moveBetweenJars`, `payCard`, `markPaid`, percent validation), `Reminders` (pure `ReminderPlanner` + local-notification scheduler, attached once in `RootView` via `.reminderScheduling()`), `ReminderSettingsView`. Strings: `Budget.xcstrings` via `loc("…")`. Debug: launch with `-budgetDemo` (empty store) and `-budgetSegment wallets|bills`.
- `Moonee/Features/Account` — Account tab (spec §6): `ProfileForm`/`AvatarPicker` (reused by onboarding; avatars `avatar.*`), `SecurityView` + `.appLock()` (Face ID lock, App Switcher cover; keys `Prefs.appLock`…), `LanguageCurrencyView`, `DataView` (`CSVExport`, `DataReset.deleteAll`). Strings in `Account.xcstrings` (also used by `AISettingsView`).
- `Moonee/Features/{Account,Wallets,Jars}` — settings screens: categories, wallets (`WalletsSection` is also the Budget segment; credit cards with statement/due day and "Pay card"), jar percents/add/rename/recolour (`JarSettingsView`), category → jar mapping.

## Known gaps vs the spec (fix before building on them)
- iCloud sync is not switched on: no iCloud capability/entitlements yet (needs the team; S11). The schema is ready.
- Ledger sums every currency as-is (no FX). Fine while all wallets use the default currency.
- `SpeechInput` is fixed to vi-VN.
- Schema v2 has no migration from v1: delete the app from the simulator if it fails to launch with an old store.

## Conventions
- Add new `@Model` types in your feature folder and register them in `Schema.mooneeModels` (Models.swift). Keep them CloudKit-ready (defaults/optionals, optional relationships with inverses, no `.unique`).
- Every txn creator (chat, form, import, onboarding) calls `txn.allocate(jars:in:)` once at save: it pins the expense jar and writes the income splits, so later percent edits / category remaps never change jar history.
- Money: store minor units + `currencyCode`, format with `Money.formatted()`, compute with `Ledger`. Never `"\(amount)đ"`.
- UI text goes through the String Catalog (English key + `vi`); store keys, not translated text.
- Secrets (API keys) go in Keychain, never SwiftData/UserDefaults.
- All money numbers are computed in Swift; the LLM only explains them (spec §9.3).
- Keep it small: native frameworks first (Speech, Vision, URLSession), add a Swift package only when a framework can't do it.
- Each feature keeps its UI strings in its own String Catalog table (`Features/<X>/<X>.xcstrings`, `Text("…", tableName: "<X>")` / `String(localized:table:)`) so parallel branches don't conflict in `Localizable.xcstrings`.
- Shared settings use the keys in `Prefs`; amounts on screen use `AmountText` (respects hidden balances).
