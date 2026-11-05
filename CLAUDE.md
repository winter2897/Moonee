# Moonee

iOS personal-finance app (SwiftUI + SwiftData, iOS 18+, Vietnamese UI, VND only). Offline-first: data lives on device.

## Build & test
```bash
xcodebuild test -project Moonee.xcodeproj -scheme Moonee -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build
```
The project uses file-system synchronized groups: drop a `.swift` file anywhere under `Moonee/` or `MooneeTests/` and it is compiled — never edit `project.pbxproj` to add files. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

## Layout
- `Moonee/App` — `MooneeApp` (ModelContainer schema list) and `RootView` (4 tabs: Nhập, Chi tiêu, Ví, Tài khoản).
- `Moonee/Core/Models.swift` — `Txn`, `Category`, `Wallet`, `Jar` + first-launch `Seed`. `Txn.amount` is a positive `Int` VND; `kind` (.expense/.income) gives the sign. `Txn.source` records origin (manual/text/voice/photo/bank); `rawInput` keeps the original text for AI. `category == nil` means "chưa phân loại" — the AI accountant fills it later. Wallet balance is computed from its txns.
- `Moonee/Core/Theme.swift` — colors (`.mooneeGreen`, `.mooneeDark`, `.mooneeInk`, `.mooneeYellow`), `Int.vnd` ("250.000 đ"), `MooneeBackground`, `.card()`, `.mooneeScreen(title)`, `IconBadge`, `PillPicker`, `MooneeButtonStyle`, `Hills`. Reuse these; match the mockup look (mint glass cards, green pill buttons).
- `Moonee/Features/<Feature>/` — one folder per feature. Account tab rows link to `JarsView`, `AccountantView`, `BankLinkView`; each feature owns its own folder/files.

## Conventions
- Add new `@Model` types in your feature folder and register them in the `ModelContainer(for:)` list in `MooneeApp.swift`.
- Secrets (API keys, bank tokens) go in Keychain, never SwiftData/UserDefaults.
- Keep it small: native frameworks first (Speech, Vision, BackgroundTasks, URLSession), add a Swift package only when a framework can't do it.
