# Moonee: Lộ trình thực hiện theo session

> Kế hoạch của CEO/CTO, 05/11/2026. Spec gốc là `docs/FEATURES.md` (spec thắng khi lệch).
> Mỗi session = một việc riêng, một nhánh, một PR vào `main`. Session 0 điều phối và review.

## Quyết định đã chốt thêm (05/11)

| Chủ đề | Quyết định |
|---|---|
| iOS tối thiểu | **iOS 26** (Foundation Models dùng thẳng, không `#available`) |
| Thẻ lọ | Số lớn = **số dư hiện tại** của lọ (envelope, cộng dồn). Thanh % = đã chi tháng này / (dư đầu tháng + tiền chia vào tháng này). Giữ layout mockup |
| Quan tâm trong MVP | **Tài sản nhập tay** (user tự nhập số lượng + giá) → net worth = ví + tài sản − nợ. Giá live, watchlist, cảnh báo giá để Bản 2 |
| Apple Developer | Đã có → CloudKit + TestFlight làm được trong MVP |
| Kiếm tiền | **Trả tiền khi tải** (paid app). Không StoreKit/IAP, không gating tính năng. Thẻ "Moonee Pro – Sở hữu trọn đời" trong mockup Tài khoản bỏ đi |
| Hồ sơ | Chỉ tên + avatar lưu trên máy, không đăng nhập. Mở app lần đầu vào màn **Thiết lập hồ sơ** (mockup `Mint Moonee Profile Setup Onboarding.png`): tên hiển thị + chọn 1 trong 7 avatar, nút Tiếp tục / Để sau, thanh Bước 1/4 |
| Đồng xu trung tính | Tạm bỏ qua, dùng đồng xu ₫ hiện có; user tự sửa sau |
| Bundle ID | Giữ `com.haiquan.moonee`. Team ID: S11 lấy từ tài khoản Xcode |

## Tài nguyên thiết kế

Nằm ngoài git, ở `/Users/haiquan/Ultra/moonee/asset/` (chỉ đọc, session nào cũng mở được):

- `ui/` — 6 mockup: Tổng quan, Ngân sách (các lọ), Moonee chat, Quan tâm, Tài khoản, Thiết lập hồ sơ (onboarding bước 1/4).
- `moonee/01–08.png` (1254², nền trong) — đủ 8 trạng thái nhân vật của spec mục D:
  01 lỗi/bối rối · 02 buồn ngủ · 03 lo lắng · 04 ăn mừng · 05 vui/đã lưu · 06 đang nghĩ · 07 đang nghe · 08 chào/idle.
- `gif/` — 9 GIF động (~309×623) cùng nhân vật: idle, cầm đồng xu, cầm cúp, cầm mic, dấu hỏi, cầm vật phẩm.
- `logo/Moonee App Icon.png` (1254², không alpha).
- `avatar/` — 7 avatar cho màn Thiết lập hồ sơ (1254², nền trắng, đã có vòng tròn viền mint; app cắt tròn và thu nhỏ khoảng 256px): Cậu bé đẹp trai, Cô gái áo vàng, Cậu bé đội mũ, Cô gái áo hồng, Mèo cam tinh nghịch, Chú chó hài hước, Cây tiền.

Thiếu: **avatar nhỏ** (đầu nhân vật) cho tab bar / chat — S2 tự cắt từ ảnh sẵn có. Đồng xu trung tính: tạm bỏ qua.

## Sơ đồ phụ thuộc

```
Đợt 1 (song song)      S1 Nền tảng ─┐   S2 Design system ─┐   S3 AI engine ─┐
                                    ▼                     ▼                 ▼
Đợt 2 (sau khi S1+S2 merge)   S4 Chat Moonee (cần S3) · S5 Tổng quan + Sổ GD · S6 Ngân sách + Nhắc nhở
                              S7 Tài khoản/Bảo mật/Dữ liệu · S8 Quan tâm · S9 Model local (cần S3)
Đợt 3                         S10 Onboarding + Báo cáo tháng · S11 Release (TestFlight)
```

## Đợt 1

### S1 — Nền tảng: dữ liệu v2 + đa ngôn ngữ + iOS 26
Mọi thứ khác xây trên nó.
- Model theo spec §11: `Txn.kind` đủ 7 loại (chi/thu/chuyển ví/chuyển lọ/cho vay/đi vay/trả nợ), `toWallet`, `jar`, `debt`; `IncomeSplit`; `Jar.balance` (envelope); `Recurring`, `Goal`, `Debt`, `Asset`, `MerchantRule`; ví thêm `ewallet`, thẻ tín dụng có ngày sao kê/đến hạn/hạn mức.
- Tiền: `amount` theo đơn vị nhỏ nhất + mã tiền tệ; tiền tệ mặc định `Locale.current.currency`. Format bằng `FormatStyle`, bỏ `Int.vnd`.
- Danh mục/lọ mặc định lưu bằng `key` (`jar.essentials`…), tên user đặt lưu `customName`.
- CloudKit-ready: mọi thuộc tính có default/optional, quan hệ optional, không `@Attribute(.unique)`.
- Engine sổ cái thuần Swift + test: số dư ví, số dư lọ, chia thu nhập theo %, thẻ tín dụng (quẹt = chi, trả thẻ = chuyển ví), cho vay/đi vay không trừ lọ.
- `Localizable.xcstrings` (en mặc định + vi), chuyển hết chuỗi hard-code. Deployment target 26.0, `UIUserInterfaceStyle = Light`.

### S2 — Design system + nhân vật
- Token màu (`brand.*`, `semantic.income/expense/warning`, bảng 12 màu lọ an toàn cho người mù màu) trong `Theme.swift`.
- Đưa 8 trạng thái nhân vật vào `Assets.xcassets` + `enum MooneeMood`; phát GIF bằng ImageIO (không thêm package); tôn trọng Reduce Motion.
- Component theo mockup + spec mục E: tab bar có nút (+) nổi, `AmountText` (tabular, ẩn số dư `*****`, VoiceOver đọc chữ), thẻ lọ (thường/≥80%/vượt/âm), thẻ hoá đơn, thẻ giao dịch trong chat (thường/sửa/hoàn tác/gộp), bong bóng chat, vòng %, donut, empty state.
- Một màn **Component Gallery** (Debug) để review.

### S3 — AI engine: parser + tool + skill
- `QuickParser` đa ngôn ngữ (từ điển theo thư mục ngôn ngữ, spec §10.3), biết tiền tệ hiện tại, nhiều giao dịch/câu, đủ 7 loại, ngày tương đối. Output là struct thuần, không phụ thuộc SwiftData.
- Lớp LLM: Foundation Models (`@Generable` + tool calling), BYOK (OpenAI / Anthropic / Gemini), output JSON có schema, sai thì về fallback parser.
- Runtime skill: file hướng dẫn markdown theo ngôn ngữ + danh sách tool Swift, nạp theo ý định. Viết `transaction-parser`, `jar-budgeting`, `close-management`, `spending-coach` (bản đầy đủ + rút gọn).
- Kiểm tra license `anthropics/knowledge-work-plugins` trước khi lấy nội dung.

## Đợt 2 (sau khi S1 + S2 vào main)

| Session | Phạm vi | Spec |
|---|---|---|
| **S4 Chat Moonee** | Màn chat (tab +): nhập text/voice/ảnh, lưu ngay + thẻ giao dịch sửa/hoàn tác, học từ lần sửa, hỏi lại khi thiếu số tiền, hỏi đáp bằng tool, gợi ý trả lời nhanh, trạng thái nhân vật | §3.1–3.3 |
| **S5 Tổng quan + Sổ giao dịch** | Dashboard theo mockup, sổ giao dịch tìm/lọc/sửa/xoá, lời nhắn Moonee | §2 |
| **S6 Ngân sách + Nhắc nhở** | Các lọ, chuyển lọ, sửa %, ví (kể cả thẻ tín dụng), khoản định kỳ + "Đã trả", local notification 3 mức có giới hạn tần suất | §3.4, §4.1–4.3 |
| **S7 Tài khoản / Bảo mật / Dữ liệu** | Cài đặt theo mockup, chế độ AI + BYOK, Face ID, ẩn số dư, che App Switcher, export CSV, iCloud sync, xoá toàn bộ dữ liệu, ngôn ngữ/tiền tệ | §6 |
| **S8 Quan tâm (nhập tay)** | Tài sản nhập tay, net worth + biểu đồ theo thời gian | §5 (rút gọn) |
| **S9 Model local** | MLX Swift, danh mục model, tải/xoá, gợi ý theo RAM, entitlement tăng RAM, đánh giá tiếng Việt | §9.2 |

## Đợt 3

| Session | Phạm vi |
|---|---|
| **S10 Onboarding + Báo cáo tháng** | Bước 1/4: màn Thiết lập hồ sơ theo mockup (tên + avatar, lưu trên máy, bỏ qua được). Bước 2–4: onboarding qua chat (§7: thu nhập + ví, hoá đơn + % lọ, chế độ AI + nhắc nhở + Face ID/thông báo). Chốt sổ cuối tháng + màn báo cáo Swift Charts (§3.5) |
| **S11 Release** | CI (GitHub Actions chạy test), signing, CloudKit container, privacy manifest, metadata en+vi, giá bán (paid app), TestFlight |

Bản 2 (mục tiêu, sổ nợ, widget, import CSV, giá live…) lên kế hoạch sau khi MVP lên TestFlight.

## Luật chơi giữa các session
- Mỗi session đọc `CLAUDE.md`, `docs/FEATURES.md`, file này; xây đúng spec.
- Sở hữu file: S1 giữ `Core/Models.swift` + model mới; S2 giữ `Core/Theme.swift` + `Assets.xcassets` + `Core/Components/`; S3 giữ `Features/AI/` + `Features/QuickInput/`. Cần sửa file của session khác thì sửa tối thiểu cho build được và ghi rõ trong PR.
- Merge thứ tự: S1 → S2 → S3, rồi đợt 2. PR phải pass `xcodebuild test`.

## Trạng thái (06/11/2026)
MVP đã vào `main` (PR #2–#24): đợt 1–3, UI review, tab bar glass, BYOK DeepSeek + chọn model, chat có lịch sử / ô nhập mới / tìm web / mức nỗ lực / skill riêng. Bản build App Store đóng gói được; việc của owner ở `docs/RELEASE.md` (tải lên, giá bán, deploy schema CloudKit, gửi duyệt).
Đã cân nhắc và bỏ: tab bar hệ thống iOS 26 (PR #25) vì làm mất (+) nổi của mockup.

## Còn chờ quyết định
- Giá bán trên App Store (chốt ở S11).
