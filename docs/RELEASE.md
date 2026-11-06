# Moonee release guide (v1.0.0)

Everything up to the upload is in the repo. Steps marked **Owner** need the Apple account owner: they change App Store Connect or the developer portal.

| | |
|---|---|
| Bundle ID | `com.haiquan.moonee` |
| Team | Quan Tran (`WXNAFMHDN8`), automatic signing |
| Version / build | `MARKETING_VERSION` 1.0.0 / `CURRENT_PROJECT_VERSION` 1 (raise the build number for every upload) |
| iCloud | CloudKit container `iCloud.com.haiquan.moonee`, private database, push (`aps-environment`), background mode `remote-notification` |
| Other entitlements | `com.apple.developer.kernel.increased-memory-limit` (local models) |
| Business model | Paid upfront, no in-app purchases, no ads |
| Category | Finance (secondary: Productivity) |
| Devices | iPhone only, iOS 26+, portrait, light mode |
| CI | `.github/workflows/test.yml`: `xcodebuild test` on every PR and push to `main` |

## 1. Build the App Store package locally

```bash
xcodebuild archive -project Moonee.xcodeproj -scheme Moonee -configuration Release -destination 'generic/platform=iOS' -archivePath build/Moonee.xcarchive -derivedDataPath build -allowProvisioningUpdates
```

```bash
xcodebuild -exportArchive -archivePath build/Moonee.xcarchive -exportPath build/export -exportOptionsPlist tools/ExportOptions.plist -allowProvisioningUpdates
```

Result: `build/export/Moonee.ipa` (`build/` is gitignored). `tools/ExportOptions.plist` is `method = app-store-connect` with `destination = export`, so nothing is uploaded. `-allowProvisioningUpdates` lets Xcode use the Apple ID in Xcode → Settings → Accounts to register the App ID, the iCloud container and the profiles.

Check the signed app before uploading:

```bash
rm -rf build/ipa && unzip -q build/export/Moonee.ipa -d build/ipa && codesign -d --entitlements - build/ipa/Payload/Moonee.app
```

Signed by "Apple Distribution: Quan Tran (WXNAFMHDN8)", it must show `aps-environment = production`, `com.apple.developer.icloud-container-environment = Production`, the container `iCloud.com.haiquan.moonee` and `increased-memory-limit`.

## 2. iCloud (CloudKit) — **Owner**

The app opens SwiftData with `cloudKitDatabase: .private("iCloud.com.haiquan.moonee")` (`Moonee/App/CloudSync.swift`). If CloudKit cannot start it falls back to the same store on device only. Account → Data shows the real state: On / sign in to iCloud / unavailable / off.

1. [Identifiers → iCloud Containers](https://developer.apple.com/account/resources/identifiers/list/cloudContainer): `iCloud.com.haiquan.moonee` was registered by automatic signing on 2026-11-06 (the App Store profile "iOS Team Store Provisioning Profile: com.haiquan.moonee" already carries it). If it is ever missing: **+** → iCloud Containers → Continue → Description `Moonee`, Identifier `iCloud.com.haiquan.moonee` → Continue → Register.
2. [Identifiers → App IDs](https://developer.apple.com/account/resources/identifiers/list) → `com.haiquan.moonee`: **iCloud** on (CloudKit, container above ticked via Edit), **Push Notifications** on, **Increased Memory Limit** on → Save. Automatic signing sets these; this is a check.
3. Create the schema in the Development environment: run a Debug build on an iPhone or a simulator **signed into iCloud**, add one transaction, wait ~30 s. [CloudKit Console](https://icloud.developer.apple.com) → `iCloud.com.haiquan.moonee` → Development → Schema → Record Types now lists `CD_Txn`, `CD_Jar`, `CD_Category`, … (one per model).
4. CloudKit Console → the container → **Deploy Schema Changes…** → Deploy to Production. TestFlight and App Store builds use Production: without this step sync does nothing for testers.
5. Every later model change: add properties only (never rename or delete: CloudKit cannot), then repeat 3–4 before that build ships. `CloudKitSchemaTests` keeps the schema CloudKit-compatible.

Fresh installs (a reinstall, a new iPhone without a backup) seed the default jars/categories before iCloud delivers the old ones. `Seed.mergeDuplicates` (at launch and after each iCloud import) keeps the oldest copy of each default by `createdAt` and moves transactions, splits, goals and rules onto it. The new install's empty "Cash wallet" is not merged (wallets have no key); the user can delete it.

## 3. App Store Connect metadata

### English (primary, en-US)

**Name** (≤30): `Moonee: Money & Budget Jars`

**Subtitle** (≤30): `Log spending by chat or voice`

**Promotional text** (≤170):
> Say it, type it or snap the receipt: Moonee logs it, sorts it and splits your income into jars. Paid once. No account, no ads, no subscription. Your data stays yours.

**Keywords** (≤100; no spaces after commas; name words are indexed already):
`budget,expense tracker,envelope,spending,finance,wallet,receipt,savings,bills,AI,ledger,personal`

**Description**:
```
Moonee is the money buddy that lives in your pocket. Tell it what you spent the way you'd tell a friend, and it does the bookkeeping.

LOG IT IN ONE LINE
• Type "pho 45k, coffee 30k" or just say it: Moonee saves both and picks the category and the wallet.
• Snap a receipt and Moonee reads the amount.
• Every entry is saved right away with a card to fix or undo, and Moonee learns from your fixes.
• Income, transfers, credit cards, lending and borrowing: all seven kinds of money moves.

JARS THAT KEEP YOUR PLAN
• Your income is split into jars by percent (essentials, savings, investing, growth, play, giving). Rename, add and recolour them.
• Jar balances carry over month to month, like real envelopes.
• See at a glance what's left in each jar and what you spent this month.

BILLS AND REMINDERS
• Rent, internet, subscriptions: Moonee reminds you before they're due, as often as you like.
• Credit cards with statement and due dates, and a one-tap "Pay card".

THE BIG PICTURE
• Today, this week and this month at a glance.
• Net worth from your wallets and the assets you track.
• A monthly report with charts.
• Ask Moonee: "How much did I spend on food this month?" Every number is computed on your iPhone, never guessed by AI.

PRIVATE BY DESIGN
• No account, no server, no ads, no tracking.
• Your books live on your iPhone and sync through your own private iCloud.
• Face ID lock, hidden balances, and a privacy cover in the app switcher.
• AI runs on your iPhone (Apple Intelligence or an open model you download). Prefer a cloud model? Bring your own key; Moonee shows exactly what is sent.
• Export everything to CSV, or delete it all, any time.

PAY ONCE, KEEP IT
No subscription and no in-app purchases. Every feature is included.

In English, Vietnamese, Thai and Lao.
```

**What's New** (1.0.0): `Hello! This is the first Moonee.`

### Vietnamese (vi)

**Tên** (≤30): `Moonee: Sổ thu chi & Lọ tiền`

**Phụ đề** (≤30): `Ghi chi tiêu chỉ bằng một câu`

**Văn bản quảng cáo** (≤170):
> Nói, gõ hay chụp hoá đơn là xong: Moonee tự ghi, tự phân loại và chia thu nhập vào các lọ. Mua một lần, không tài khoản, không quảng cáo. Dữ liệu là của bạn.

**Từ khoá** (≤100):
`chi tiêu,thu chi,ngân sách,quản lý tiền,6 hũ,tiết kiệm,hoá đơn,ví,tài chính,AI`

**Mô tả**:
```
Moonee là người bạn giữ tiền nằm gọn trong túi bạn. Kể chuyện chi tiêu như kể với bạn bè, Moonee lo phần sổ sách.

GHI CHỈ BẰNG MỘT CÂU
• Gõ "phở 45k, cafe 30k" hoặc nói luôn: Moonee lưu cả hai, tự chọn danh mục và ví.
• Chụp hoá đơn, Moonee đọc số tiền.
• Mỗi giao dịch được lưu ngay kèm thẻ để sửa hoặc hoàn tác, và Moonee học từ những lần bạn sửa.
• Thu nhập, chuyển ví, thẻ tín dụng, cho vay và đi vay: đủ bảy loại giao dịch.

CÁC LỌ GIỮ KẾ HOẠCH
• Thu nhập tự chia vào các lọ theo % (thiết yếu, tiết kiệm, đầu tư, phát triển, hưởng thụ, cho đi). Đổi tên, thêm lọ, đổi màu tuỳ ý.
• Số dư lọ cộng dồn qua các tháng như phong bì thật.
• Nhìn là biết mỗi lọ còn bao nhiêu và tháng này đã chi bao nhiêu.

HOÁ ĐƠN VÀ NHẮC NHỞ
• Tiền nhà, internet, các gói đăng ký: Moonee nhắc trước hạn, ít hay nhiều tuỳ bạn.
• Thẻ tín dụng có ngày sao kê, ngày đến hạn và nút "Trả thẻ".

BỨC TRANH TOÀN CẢNH
• Hôm nay, tuần này, tháng này chi bao nhiêu.
• Tài sản ròng từ các ví và tài sản bạn theo dõi.
• Báo cáo tháng có biểu đồ.
• Hỏi Moonee: "Tháng này ăn uống hết bao nhiêu?" Mọi con số đều được tính trên iPhone, AI không đoán.

RIÊNG TƯ TỪ THIẾT KẾ
• Không tài khoản, không máy chủ, không quảng cáo, không theo dõi.
• Sổ sách nằm trên iPhone và đồng bộ qua iCloud riêng của bạn.
• Khoá bằng Face ID, ẩn số dư, che màn hình khi chuyển ứng dụng.
• AI chạy ngay trên iPhone (Apple Intelligence hoặc model mở bạn tải về). Muốn dùng model trên mây? Dùng khoá API của chính bạn, Moonee cho xem rõ những gì được gửi đi.
• Xuất toàn bộ ra CSV hoặc xoá sạch bất cứ lúc nào.

MUA MỘT LẦN, DÙNG MÃI
Không gói đăng ký, không mua trong ứng dụng. Có đủ mọi tính năng.

Có tiếng Việt, tiếng Anh, tiếng Thái và tiếng Lào.
```

**Có gì mới** (1.0.0): `Xin chào! Đây là phiên bản Moonee đầu tiên.`

### Thai (th)

**ชื่อ** (≤30): `Moonee: บันทึกรายรับรายจ่าย`

**คำบรรยายย่อ** (≤30): `จดรายจ่ายแค่พิมพ์ประโยคเดียว`

**ข้อความโปรโมท** (≤170):
> พูด พิมพ์ หรือถ่ายรูปใบเสร็จก็จบ Moonee จดให้ จัดหมวดหมู่ให้ และแบ่งรายรับลงกระปุกให้เอง จ่ายครั้งเดียว ไม่ต้องสมัครบัญชี ไม่มีโฆษณา ข้อมูลเป็นของคุณ

**คำค้น** (≤100):
`รายรับรายจ่าย,บัญชีรายจ่าย,งบประมาณ,ออมเงิน,6 กระปุก,จัดการเงิน,ใบเสร็จ,กระเป๋าเงิน,การเงิน,AI`

**คำอธิบาย**:
```
Moonee คือเพื่อนคู่ใจเรื่องเงินที่อยู่ในกระเป๋าคุณ เล่าเรื่องการใช้เงินเหมือนเล่าให้เพื่อนฟัง ที่เหลือ Moonee จัดการให้

จดแค่ประโยคเดียว
• พิมพ์ "กาแฟ 65บาท ข้าวมันไก่ 50" หรือพูดเลยก็ได้ Moonee บันทึกทั้งสองรายการ เลือกหมวดหมู่และกระเป๋าเงินให้เอง
• ถ่ายรูปใบเสร็จ Moonee อ่านยอดเงินให้
• ทุกรายการบันทึกทันที พร้อมการ์ดให้แก้ไขหรือเลิกทำ และ Moonee จำจากที่คุณแก้
• รายรับ โอนระหว่างกระเป๋า บัตรเครดิต ให้ยืมและยืม: ครบทั้งเจ็ดแบบ

กระปุกช่วยคุมแผน
• รายรับแบ่งลงกระปุกตาม % ให้อัตโนมัติ (จำเป็น ลงทุน เงินออม พัฒนาตัวเอง ความสุข แบ่งปัน) เปลี่ยนชื่อ เพิ่มกระปุก หรือเปลี่ยนสีได้ตามใจ
• ยอดในกระปุกยกยอดข้ามเดือนเหมือนซองเงินจริง
• ดูปุ๊บรู้ปั๊บว่าแต่ละกระปุกเหลือเท่าไหร่ และเดือนนี้ใช้ไปเท่าไหร่

บิลและการแจ้งเตือน
• ค่าเช่า ค่าเน็ต ค่าสมาชิกต่างๆ: Moonee เตือนก่อนครบกำหนด มากหรือน้อยแล้วแต่คุณ
• บัตรเครดิตมีวันสรุปยอด วันครบกำหนด และปุ่ม "จ่ายบัตร"

เห็นภาพรวมทั้งหมด
• วันนี้ สัปดาห์นี้ เดือนนี้ ใช้ไปเท่าไหร่
• ความมั่งคั่งสุทธิจากกระเป๋าเงินและสินทรัพย์ที่คุณติดตาม
• รายงานประจำเดือนพร้อมกราฟ
• ถาม Moonee ได้เลย: "เดือนนี้ค่ากินไปเท่าไหร่?" ตัวเลขทุกตัวคำนวณบน iPhone AI ไม่เดา

ความเป็นส่วนตัวตั้งแต่การออกแบบ
• ไม่ต้องมีบัญชี ไม่มีเซิร์ฟเวอร์ ไม่มีโฆษณา ไม่มีการติดตาม
• ข้อมูลอยู่บน iPhone และซิงค์ผ่าน iCloud ส่วนตัวของคุณ
• ล็อกด้วย Face ID ซ่อนยอดเงิน และปิดหน้าจอตอนสลับแอป
• AI ทำงานบน iPhone (Apple Intelligence หรือโมเดลเปิดที่คุณดาวน์โหลด) อยากใช้โมเดลบนคลาวด์? ใช้ API key ของคุณเอง Moonee แสดงให้เห็นชัดว่าส่งอะไรออกไปบ้าง
• ส่งออกทั้งหมดเป็น CSV หรือลบทิ้งได้ทุกเมื่อ

จ่ายครั้งเดียว ใช้ได้ตลอด
ไม่มีค่าสมาชิก ไม่มีการซื้อในแอป ได้ทุกฟีเจอร์ครบ

มีภาษาไทย ลาว อังกฤษ และเวียดนาม
```

**มีอะไรใหม่** (1.0.0): `สวัสดี! นี่คือ Moonee เวอร์ชันแรก`

### Lao (lo)
App Store Connect has no Lao store localization, so the Lao storefront shows the English (or Thai) page. The app itself ships `lo`; mention it in the English description ("In English, Vietnamese, Thai and Lao").

### URLs (every language) — **Owner**
- **Privacy Policy URL** (required). One page is enough, e.g. "Moonee collects no data. Your records stay on your device and in your private iCloud. If you add your own AI provider key, the text you send to Moonee's assistant goes from your device to that provider under your own account with them."
- **Support URL** (required): a page with a contact email.
- Marketing URL: optional.
- **Before the build you submit**: `AppLinks` in `Moonee/Features/Account/AccountView.swift` still holds placeholders. Set `feedback` to `mailto:<support email>?subject=Moonee%20feedback` and `appStore` to `https://apps.apple.com/app/id<Apple ID>` (the numeric Apple ID shown under App Information once the app record exists). Account → Share Moonee / Help & feedback use them.

## 4. App Privacy

App Store Connect → App Privacy → Get Started → **"No, we do not collect data from this app"** → shows **Data Not Collected**.

Why (Apple: "collect" = sent off the device so that you or your partners can access it beyond serving the request):
- No server, analytics, crash SDK, ads or account. `Moonee/PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected data types.
- iCloud sync uses the user's **private** CloudKit database, which the developer cannot read.
- Bring-your-own-key AI: the request goes from the device straight to the provider the user chose, on the user's own account and key; Moonee never sees it. AI settings say what is sent before it is turned on.
- Local model downloads from Hugging Face carry no user data.

If analytics, crash reporting or a Moonee-paid AI proxy are added later, this answer changes (owner's call).

Required-reason APIs in `PrivacyInfo.xcprivacy`: UserDefaults `CA92.1`, file timestamps `C617.1` (model files in the app container), disk space `E174.1` (free-space check before a model download).

## 5. Age rating and other answers

- Age rating: every content question **None / No** (violence, mature themes, gambling, contests, medical, unrestricted web access, user-generated content shared with others, messaging between users). Expected **4+**. If the form asks about AI/chatbots: the assistant only talks about the user's own finances.
- Made for Kids: No. Advertising identifier: No. Sign-in required: No. Third-party content: No.
- Export compliance: `ITSAppUsesNonExemptEncryption = NO` is in the Info.plist (HTTPS only), so App Store Connect does not ask.
- Usage strings (en + vi, `Moonee/InfoPlist.xcstrings`): microphone, speech recognition, camera, photo library, Face ID. Notifications have no Info.plist string on iOS; the system prompt appears when the user turns on reminders.

## 6. Screenshots

Required: **6.9"** (1320 × 2868; iPhone 17 Pro Max). Recommended: **6.3"** (1206 × 2622; iPhone 17 Pro) — if missing, App Store Connect scales the 6.9" set down. Portrait, up to 10 per size per language. Make an English, a Vietnamese and a Thai set (launch with `-AppleLanguages "(th)" -AppleLocale th_TH -money.currency THB`).

| # | Screen | Shows |
|---|---|---|
| 1 | Moonee chat after "phở 45k, cafe 30k" | One line logs two, with category + jar cards |
| 2 | Overview | Today/week spending, jars, bills due, net worth |
| 3 | Budget → Jars | Jar cards with balances and month progress |
| 4 | Jar detail / jar transfer | Envelope carry-over |
| 5 | Budget → Bills | Upcoming bills, "Paid", credit card due date |
| 6 | Moonee answering "How much on food this month?" | Numbers computed on device |
| 7 | Monthly report | Charts |
| 8 | Account → Security or AI | Face ID, hidden balances, on-device AI |

Capture from the simulator with sample data. `-budgetDemo` (Debug builds only) fills an **empty** store with wallets, a salary, expenses and bills.

```bash
xcrun simctl create "Shots 6.9" "iPhone 17 Pro Max"
```

```bash
xcrun simctl boot "Shots 6.9"; open -a Simulator
```

```bash
xcodebuild build -project Moonee.xcodeproj -scheme Moonee -destination 'platform=iOS Simulator,name=Shots 6.9' -derivedDataPath build
```

```bash
xcrun simctl install "Shots 6.9" build/Build/Products/Debug-iphonesimulator/Moonee.app
```

```bash
xcrun simctl status_bar "Shots 6.9" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
```

English (the sample amounts are VND-sized, so keep VND):

```bash
xcrun simctl launch "Shots 6.9" com.haiquan.moonee -budgetDemo -AppleLanguages "(en)" -AppleLocale en_VN -money.currency VND
```

Go through onboarding (or skip it), open each screen, type the chat lines yourself (the rule parser needs no AI setup), and capture:

```bash
xcrun simctl io "Shots 6.9" screenshot docs/screenshots/store/en-6.9-01-chat.png
```

Vietnamese: `xcrun simctl uninstall "Shots 6.9" com.haiquan.moonee`, install again (the demo needs an empty store), then

```bash
xcrun simctl launch "Shots 6.9" com.haiquan.moonee -budgetDemo -AppleLanguages "(vi)" -AppleLocale vi_VN -money.currency VND
```

Repeat with an "iPhone 17 Pro" simulator for 6.3".

## 7. TestFlight checklist

- [ ] CI green on `main`.
- [ ] CloudKit schema deployed to Production (section 2, steps 3–4).
- [ ] Build number raised, archive + export (section 1), entitlements checked.
- [ ] Upload (**Owner**, section 8). Wait for the build to finish processing.
- [ ] TestFlight → Test Information: beta description (promotional text), feedback email, what to test.
- [ ] Internal group (owner + team, up to 100): no review needed.
- [ ] External group: first build goes through Beta App Review (~1 day); use the review notes from section 8.
- [ ] On a real iPhone:
  - [ ] Fresh install: onboarding, default jars; log by text, by voice (mic + speech prompts), by receipt photo (camera + photos prompts).
  - [ ] Face ID lock, hide balances, app switcher cover.
  - [ ] Reminders: notification prompt; a bill reminder arrives.
  - [ ] iCloud: Account → Data shows **On**. Delete and reinstall (or a second iPhone on the same Apple ID): data comes back within a minute, no duplicate jars or categories.
  - [ ] Signed out of iCloud (or iCloud off for Moonee): Data shows the sign-in hint; everything else works.
  - [ ] AI: Apple Intelligence device; a local model download over Wi-Fi and a parse; BYOK with a test key.
  - [ ] CSV export opens in Numbers; Delete all data resets to a fresh install.
  - [ ] iPhone language Vietnamese: every tab and every permission prompt.
  - [ ] Thai and Lao (Account → Language): every tab, the chat, and a Thai/Lao message such as "กาแฟ 65บาท" / "ເຝີ 35ພັນ".
- [ ] TestFlight → Crashes empty after a week of use.

## 8. Owner-only steps (no session does these)

1. **Agreements**: App Store Connect → Business → accept the **Paid Apps Agreement**, add tax forms and a bank account. A paid app cannot go on sale without it.
2. **App record**: App Store Connect → Apps → **+** → New App → iOS, name `Moonee: Money & Budget Jars`, primary language English (U.S.), bundle ID `com.haiquan.moonee`, SKU `moonee-ios`, full access. Then add the Vietnamese and Thai localizations (there is no Lao one).
3. **Upload**: Xcode → Window → Organizer → the archive → Distribute App → App Store Connect → Upload; or drag `build/export/Moonee.ipa` into the Transporter app.
4. **Price**: Pricing and Availability → Price Schedule → base country + price **[PRICE — owner decides]**; Apple fills other storefronts. Availability: all countries or a list. No in-app purchases.
5. **Metadata**: section 3 in both localizations, screenshots from section 6, App Privacy from section 4, age rating from section 5, category Finance / Productivity, copyright `2026 Quan Tran`, support and privacy policy URLs.
6. **App Review Information**: no sign-in. Notes: "No account or sign-in. All data stays on device and in the user's private iCloud. The assistant parses text like 'coffee 30k' with an on-device rule parser, so it works without any AI setup; Apple Intelligence is used when available. Cloud AI is optional and needs the user's own API key. Local models are optional downloads (Account → AI → Local models). Paid upfront, no in-app purchases." Contact name, phone, email.
7. **Submit**: version page → Build → pick the TestFlight build → Add for Review → Submit; choose manual or automatic release.
