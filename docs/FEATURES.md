# Moonee: Tổng hợp tính năng

> Trợ lý tài chính cá nhân trên iOS. Nói, gõ hay chụp là xong, Moonee tự phân loại và chia vào các lọ.
> Bản nháp ngày 05/11/2026, chốt sau buổi brainstorm. Các mục **⚠️** là chỗ cần bạn check lại.

---

## 0. Quyết định đã chốt

| Chủ đề | Quyết định |
|---|---|
| Người dùng | Cả hai: mặc định cho người phổ thông, có mục **Nâng cao** cho power user |
| Nền tảng | Chỉ iOS (SwiftUI + SwiftData + CloudKit) |
| Kiếm tiền | **Mua đứt một lần**: trả tiền khi tải trên App Store, không IAP |
| AI chạy ở đâu | User chọn trong Cài đặt: model local (model mở như Gemma, Qwen... tải về và chạy trên máy) hoặc BYOK. Moonee **không** trả phí LLM thay user |
| Skill của trợ lý | Dựa trên bộ skill Finance của Anthropic, custom lại cho tài chính cá nhân (mục 9.4) |
| Lưu giao dịch | Lưu ngay, kèm thẻ sửa/hoàn tác |
| Kênh nhập ngoài chat | Widget + Lock Screen |
| Mức nhắc nhở | User tự chọn: Ít / Vừa / Nhiều (mặc định Vừa) |
| Sổ nợ | Có, bản cơ bản |
| Mô hình lọ | Số dư thật, cộng dồn qua các tháng (envelope) |
| Chia thu nhập | Tự chia theo từng lần nhận, sửa tay được cho từng khoản |
| Ngân hàng | Ví tạo thủ công + import sao kê; **không** liên kết API trong MVP |
| Quan tâm | Watchlist + tài sản đang giữ → net worth, có cảnh báo giá |
| Bảo mật | Face ID/passcode, ẩn số dư, che màn hình khi chuyển app, xoá toàn bộ dữ liệu |
| Import/Export | CSV/Excel hai chiều |
| Onboarding | Thiết lập qua chat |
| Visual | Trẻ trung, năng động, gradient, animation. Xanh lá/mint + vàng trên nền mint nhạt. Nhân vật: chiếc ví xanh cầm đồng xu vàng |
| Giao diện | **Chỉ light mode**, chưa làm dark mode |
| Xưng hô | "Moonee – Bạn" |
| Ngôn ngữ | English (mặc định), Tiếng Việt, ภาษาไทย, ພາສາລາວ. Kiến trúc sẵn sàng để thêm ngôn ngữ khác dễ dàng |
| Tiền tệ | Tách khỏi ngôn ngữ. Tự nhận theo vùng của máy, user đổi được |

Chi tiết về các chế độ AI, model on-device và skill ở **mục 9**.

---

## 1. Thanh tab

```
[ Tổng quan ]  [ Ngân sách ]  [ (+) Moonee ]  [ Quan tâm ]  [ Tài khoản ]
```

- Mở app thì vào **Tổng quan**.
- Nút **(+)** nổi ở giữa thanh tab tự vẽ (giữ layout mockup, có pill glass khi chọn tab; không dùng tab bar hệ thống). Nhấn vào là mở chat, chưa bật bàn phím để thấy các gợi ý; ô nhập và mic sẵn sàng.
- **Sổ giao dịch** (xem, tìm, lọc, sửa lịch sử) nằm trong Tổng quan, dạng "Giao dịch gần đây → Xem tất cả".
---

## 2. Tổng quan (dashboard)

- Hôm nay / tuần này đã chi bao nhiêu
- Số dư từng lọ (dạng vòng hoặc thanh tiến độ)
- Hoá đơn sắp đến hạn (7 ngày tới)
- Giao dịch gần đây → **Sổ giao dịch** đầy đủ (tìm kiếm, lọc theo ví/lọ/danh mục/ngày, sửa, xoá)
- Thẻ **Net worth** (tóm tắt từ mục Quan tâm)
- Lời nhắn ngắn từ Moonee (một câu insight, theo mức nhắc nhở)
- Thẻ báo cáo cuối kỳ khi có (tuần/tháng/năm)

## 3. Moonee (chat + nhập liệu)

### 3.1 Nhập tự nhiên
- **Text / Voice / Ảnh.** Ảnh gồm hoá đơn, biên lai chuyển khoản, ảnh chụp màn hình app ngân hàng.
- Hiểu cách nói tiếng Việt: `30k`, `1 củ`, `2 lít`, `1tr2`, `hôm qua`, `sáng nay`, `thứ 2 tuần trước`.
- Nhiều giao dịch trong một câu: "phở 45k, cafe 29k, grab 32k" → 3 giao dịch.
- Nhận diện loại: **chi / thu / chuyển ví / chuyển lọ / cho vay / đi vay / trả nợ**.
- Voice: dùng Speech framework on-device.

### 3.2 Sau khi parse
- **Lưu ngay** rồi hiện **thẻ giao dịch** (số tiền, danh mục, lọ, ví, ngày, ghi chú). Nhấn để sửa, có nút **Hoàn tác**.
- **Học từ lần sửa:** user đổi danh mục cho "Highlands" thì lần sau Moonee tự gán đúng (lưu cặp merchant → danh mục ở máy).
- Thiếu thông tin quan trọng (không có số tiền) thì Moonee hỏi lại thay vì đoán.

### 3.1b Lịch sử chat và ô nhập
- Mỗi ngày một cuộc chat, sang ngày mới tự mở cuộc mới; user tạo cuộc mới, ghim (sao), xoá bất kỳ cuộc nào (xoá chat không xoá giao dịch).
- Ô nhập: lúc nghỉ là một thanh gọn ((+), "Nhập hoặc giữ để nói", mic, nút giữ để nói); khi gõ mở rộng kèm chip model · mức nỗ lực và nút gửi.
- (+) mở "Thêm vào cuộc trò chuyện": máy ảnh, ảnh gần đây, ảnh hoá đơn, Skills, bật/tắt tìm web.
- Mức nỗ lực: Thấp / Trung bình (mặc định) / Cao / Cao hơn / Tối đa, chỉ hiện khi model hỗ trợ.

### 3.3 Hỏi đáp và tư vấn
- **Tìm web** khi user hỏi thông tin bên ngoài (giá vàng, Bitcoin...). Trả lời luôn kèm nguồn và thời điểm; Moonee chỉ đọc số từ tool, không đoán. Thứ tự (quyết định 06/11):
  1. **Search có sẵn của provider**, khi model trả lời là của provider đó: OpenRouter (web plugin), OpenAI (tool `web_search`), Anthropic (server tool web search), Gemini (grounding `google_search`). Ở chế độ Lai, câu hỏi thị trường đi BYOK trước để dùng search này.
  2. **Key Tavily/Brave của user**, chỉ khi model không có search sẵn: model local, DeepSeek, Custom.
  3. **Nguồn công khai không cần key**, luôn có ở mọi chế độ (tool `marketPrice`), cho câu hay hỏi nhất: giá vàng SJC và nhẫn PNJ 999.9 (feed giá công khai của PNJ, đổi sang giá mỗi lượng trong Swift; sjc.com.vn chặn bot nên không dùng), tỷ giá ra VND (bảng tỷ giá công khai của Vietcombank), crypto (CoinGecko). Timeout 8 giây, cache 5 phút (Vietcombank yêu cầu tối đa 1 lần mỗi 5 phút). Chỉ gửi tên thứ được hỏi, không gửi dữ liệu của user. Có giá từ nguồn này thì không cần tìm web.
  - **Không nêu tên nhà cung cấp giá** (quyết định 06/11): mọi chữ user thấy (câu trả lời, số liệu, mục "Dữ liệu nào rời khỏi iPhone", Tìm kiếm web) chỉ nói "giá tham khảo trên internet"; sản phẩm vàng gọi chung (vàng miếng 999.9, nhẫn trơn 999.9); chip nguồn ghi "Internet". Bài viết từ tìm web vẫn giữ link và tên trang.
  - Câu khác (chứng khoán, lãi suất, tin tức) mà không có 1 hoặc 2 thì Moonee nói thật và chỉ cách bật. Mục "Tìm kiếm web" trong Cài đặt AI ghi rõ đang dùng đường nào.
- **Model nhỏ** (model local) nhận **prompt rút gọn** (persona + skill bản ngắn + FACTS cắt gọn + 4 lượt chat gần nhất); tràn context thì thử lại không kèm lịch sử. Lỗi thì chuyển sang bộ parse quy tắc và số liệu của app (chế độ Lai: sang model cloud cho câu hỏi), kèm một câu báo thân thiện trong chat. Không tự chuyển sang cloud khi user chọn Model local.
- **Không tư vấn đầu tư** (quyết định 07/11): Moonee không bao giờ khuyên mua, bán hay giữ cổ phiếu, quỹ, crypto, vàng, ngoại tệ cụ thể và không dự đoán giá; được hỏi thì từ chối nhẹ nhàng, nói chỉ phân tích được số liệu user nhập và gợi ý hỏi chuyên gia có giấy phép (luật cứng trong persona + skill `market-lookup`, `jar-budgeting`, mọi ngôn ngữ, bản đầy đủ và bản ngắn). Tính toán ngân sách trên số của user (lọ, tỷ lệ tiết kiệm, quỹ khẩn cấp) vẫn làm. Câu trả lời về thị trường hay đầu tư (skill `market-lookup` hoặc câu hỏi có từ đầu tư/cổ phiếu/vàng/crypto…) có dòng cuối in nghiêng "Thông tin tham khảo, không phải lời khuyên đầu tư"; câu khác thì không.
- **Giọng Moonee**: nói như bạn thân nhắn tin, tự nhiên, ấm, 1–3 câu, không emoji, ở mọi câu trả lời và câu hỏi lại. Ghi giao dịch xong thì tóm tắt một câu ("Moonee ghi lại 40.000 ₫ ăn sáng ở GS25 hôm nay rồi nhé").
- "Tháng này mình ăn uống hết bao nhiêu?", "Còn bao nhiêu để hưởng thụ?"
- Gợi ý cân đối lọ cuối tháng dựa trên thu nhập và thói quen chi.
- Hướng dẫn đạt mục tiêu: "Muốn mua laptop 30tr trước Tết thì mỗi tuần cần để dành bao nhiêu?"

### 3.4 Nhắc nhở (theo mức user chọn)
| Mức | Nội dung |
|---|---|
| Ít | Hoá đơn đến hạn, lọ vượt 100% |
| Vừa (mặc định) | + lọ chạm 80%, báo cáo tuần/tháng, nhắc thu/trả nợ |
| Nhiều | + nhắc ghi chép mỗi tối, nhận xét giao dịch lớn, gợi ý hằng ngày |

- Dùng local notification, không cần server.
- Giới hạn tần suất để tránh spam (ví dụ tối đa N thông báo mỗi ngày, gộp các cảnh báo cùng loại).

### 3.5 Báo cáo
- Cuối tuần / tháng / năm, Moonee gửi một thẻ báo cáo trong chat. Nhấn vào là mở màn hình báo cáo:
  - Biểu đồ chi theo lọ, theo danh mục, so sánh với kỳ trước
  - Top khoản chi, xu hướng
  - Lời khuyên từ Moonee
- Vẽ bằng Swift Charts.

## 4. Ngân sách

### 4.1 Các lọ (envelope)
- Mặc định 6 lọ: Thiết yếu 55% · Đầu tư 10% · Tiết kiệm 10% · Phát triển bản thân 10% · Hưởng thụ 10% · Từ thiện 5%.
- Thêm, bớt, đổi tên, đổi màu/icon và sửa % (tổng phải đủ 100%).
- **Mỗi khoản thu mới** được chia ngay vào lọ theo %, không cần bấm gì (ví dụ "nhận thưởng 5tr" trong chat). Sửa tay được cho từng khoản (ví dụ thưởng cho 100% vào Đầu tư). Lương định kỳ thì chia theo kế hoạch của Moonee tuỳ mức hỗ trợ (mục 4.6).
- **Chi tiêu trừ thẳng vào lọ**, xác định qua danh mục (mỗi danh mục thuộc một lọ).
- Số dư **cộng dồn** sang tháng sau. Lọ âm thì Moonee gợi ý lấy từ lọ nào, bao nhiêu (mục 4.6).
- **Chuyển giữa các lọ** bằng thao tác tay hoặc qua chat.
- **Không có tiền nằm ngoài lọ** (quyết định 06/11, kiểu envelope như YNAB "Ready to assign"):
  - **Chỉ tiền để tiêu mới vào lọ** (quyết định 06/11, đợt 2): **ví tính vào ngân sách = tổng các lọ + Chưa chia vào lọ**, luôn đúng.
  - **Chưa chia vào lọ** = tổng số dư các ví bật "Tính vào ngân sách" (thẻ tín dụng tính âm) − tổng số dư các lọ. Tài khoản tiết kiệm/đầu tư (tắt "Tính vào ngân sách"), tài sản (vàng, cổ phiếu, crypto) và tiền cho mượn chỉ tính vào tài sản ròng (Quan tâm), không bao giờ vào lọ hay Chưa chia. Vì thế cho mượn làm con số này giảm (tiền rời ví), đi vay làm nó tăng; chuyển giữa các ví ngân sách, rút ATM, nạp ví, trả thẻ không đổi gì.
  - Khác 0 thì tab Ngân sách hiện dòng **Chưa chia vào lọ** ngay đầu mục "Tháng này", với menu **Chia vào các lọ**: **Kế hoạch của Moonee** (mục 4.6), **Chia theo %**, hoặc **Bỏ hết vào một lọ**. Mỗi cách ghi thành một giao dịch chuyển lọ có ngày (không có lọ nguồn, mỗi lọ một phần chia), nên lịch sử các tháng trước không đổi. Âm nghĩa là các lọ hứa nhiều hơn tiền thật: Moonee gợi ý lấy bớt từ lọ nào.
  - **Tiền có sẵn** (số dư ban đầu, ví mới, sửa số dư, bán tài sản, rút tiết kiệm) đều vào đây và user quyết một lần. Onboarding cũng không tự chia nữa: số dư ví nằm ở Chưa chia vào lọ và thẻ Moonee gợi ý ở tab Ngân sách đưa kế hoạch (chế độ Tự động thì Moonee tự áp dụng).
- **Số trên tab Ngân sách** (một struct `BudgetFacts`, trợ lý đọc đúng struct này):
  - **Thu nhập** = các khoản thu trong tháng (Tổng quan dùng cùng con số).
  - **Tổng ngân sách** = số dư các lọ đầu tháng + tiền vào lọ trong tháng (chia thu nhập, chia tiền chưa chia, chuyển lọ). **Đã chi** = chi từ các lọ trong tháng. **Còn lại** = Tổng ngân sách − Đã chi = tổng số dư các lọ cuối tháng.

### 4.2 Ví / nguồn tiền
- Các loại: tiền mặt, tài khoản ngân hàng, ví điện tử (MoMo, ZaloPay...), **thẻ tín dụng**.
- Lọ và ví độc lập nhau: lọ trả lời "tiền dành cho việc gì", ví trả lời "tiền đang nằm ở đâu". Chi từ ví nào cũng trừ lọ của danh mục.
- **Tính vào ngân sách** (công tắc ở mỗi ví, quyết định 06/11): mặc định bật cho tiền mặt, ngân hàng, ví điện tử, thẻ tín dụng; tắt cho hai loại mới **Tài khoản tiết kiệm** và **Tài khoản đầu tư**. Ví tắt chỉ tính vào tài sản ròng. Danh sách ví hiện thêm dòng "Trong ngân sách" khi có ví tắt.
- **Mua tài sản / Gửi tiết kiệm** (nút + ở Ngân sách, nút + ở Quan tâm): tiền rời ngân sách thì lấy từ một lọ user chọn (mặc định Đầu tư khi mua tài sản, Tiết kiệm khi gửi tiết kiệm), ghi thành chuyển tiền có lọ (ví −, lọ −) và tăng `Asset` (số lượng, giá mua làm giá đơn vị, cộng vào giá vốn) hoặc ví tiết kiệm. **Bán tài sản / Rút tiết kiệm** đưa tiền về ví ngân sách thành Chưa chia vào lọ. Màn này nhắc quỹ khẩn cấp (mục 4.6) và nguyên tắc đầu tư, kèm câu "Moonee không phải chuyên gia tư vấn đầu tư có giấy phép".
- **Thẻ tín dụng:**
  - Lưu ngày sao kê, ngày đến hạn và hạn mức.
  - Quẹt thẻ được tính là chi tiêu (trừ lọ, tăng dư nợ thẻ).
  - Trả nợ thẻ là **chuyển ví**, không tính là chi lần hai.

### 4.3 Khoản định kỳ và hoá đơn
- Tiền nhà, điện, nước, internet, bảo hiểm, subscription, trả góp.
- Lưu chu kỳ, ngày đến hạn, số tiền (cố định hoặc ước tính), ví và lọ.
- Nhắc trước N ngày. Đến hạn thì có nút "Đã trả" để tạo giao dịch ngay.
- Tạo nhanh qua chat: "Nhắc mình đóng tiền nhà 5tr ngày 5 hàng tháng".
- **Khoản thu định kỳ (lương)** (quyết định 06/11): là một khoản định kỳ có danh mục thu (Lương). Tab Ngân sách luôn hiện "Lương · Dự kiến 10/11" với nút **Đã nhận** thấy rõ, bấm lúc nào cũng được (không chỉ vào ngày nhận): tạo khoản thu vào ví (ví của khoản đó, không có thì tài khoản ngân hàng đầu tiên trong ngân sách) và chia vào các lọ theo kế hoạch của Moonee (Tự động, Gợi ý) hoặc theo % (Tự làm). Nhận sớm thì ghi và chia ngay, ngày nhận chuyển sang kỳ sau. Chế độ Tự động thì Moonee tự ghi vào ngày nhận (mục 4.6); hai chế độ còn lại chỉ ghi khi user xác nhận. Khoản thu không cố định là ước tính, bấm Đã nhận thì nhập số thực nhận.
  - Đã ghi khoản thu cùng danh mục (ví dụ qua chat "nhận lương 15tr") từ 7 ngày trước ngày nhận trở đi thì coi như đã nhận: không hỏi lại, ngày nhận tự chuyển sang kỳ sau.
  - Khoản thu định kỳ không tính vào "hoá đơn sắp đến hạn" và không nhắc như hoá đơn.

### 4.4 Mục tiêu
- Mục tiêu có số tiền, hạn chót và lọ nguồn (ví dụ laptop lấy từ lọ Hưởng thụ).
- Hiện tiến độ và số cần để dành mỗi tuần/tháng. Moonee nhắc theo mức nhắc nhở.
- Có hiệu ứng ăn mừng khi đạt mục tiêu (nhân vật Moonee).

### 4.5 Sổ nợ (cơ bản)
- "Cho Nam mượn 2tr", "Vay mẹ 5tr" → ghi người, số tiền, ngày, hạn trả (nếu có).
- Trả một phần hoặc toàn bộ.
- Nhắc thu hoặc trả nợ khi tới hạn.
- Cho mượn/đi vay **không tính là chi/thu** vì không trừ lọ. Đây là chuyển tiền ra hoặc vào ví.

### 4.6 Moonee cố vấn (quyết định 06/11)
Moonee hành xử như một người hiểu tài chính cá nhân, trừ khi user tắt.
- **Mức hỗ trợ của Moonee** (onboarding và Tài khoản; `Prefs.advisorLevel`):
  - **Tự động:** Moonee tự ghi lương vào ngày nhận và áp dụng kế hoạch (chia tiền chưa chia, bù lọ âm), rồi báo bằng thẻ "Moonee đã ghi Lương" có **Hoàn tác** và **Sửa số tiền**. App không chạy nền: Moonee làm khi app được mở từ ngày nhận trở đi, thông báo sáng ngày lương nói vậy.
  - **Gợi ý (mặc định):** Moonee đưa kế hoạch cụ thể có số và một dòng "vì sao"; user bấm **Đồng ý / Sửa / Bỏ qua**. Không có gì di chuyển khi chưa đồng ý.
  - **Tự làm:** không gợi ý, chỉ cảnh báo (lọ âm, ví chưa có tiền, hoá đơn và thẻ đến hạn).
- **Mọi con số tính trong Swift** bằng `BudgetAdvisor` (thuần, có unit test). Văn bản là mẫu trong String Catalog; LLM chỉ diễn đạt lại (tool `monthBudget` trả `advice`), không có model thì dùng mẫu.
- **Các thời điểm**, theo thứ tự ưu tiên (thẻ ở đầu là thẻ hiện):
  1. **Ngày lương** ("Lương 40tr về chưa? Moonee đề xuất chia…"): kế hoạch cho cả khoản lương, đến kỳ lương sau. Một chạm ghi và chia. Thông báo sáng ngày lương.
  2. **Ví chưa có tiền:** ví ngân sách ≤ 0 mà có lọ âm (hoặc lọ giữ nhiều hơn ví) → "Ví chưa có tiền", nút **Cập nhật số dư ví** / **Ghi lương sớm**, không bao giờ "chuyển từ lọ khác".
  3. **Lọ âm:** nêu lọ nguồn và đúng số tiền, theo thứ tự Hưởng thụ → Phát triển → Từ thiện → lọ tự tạo → Chưa chia vào lọ → Tiết kiệm/Đầu tư sau cùng (có nói rõ). Không lấy từ Thiết yếu. Nếu chỉ Chưa chia vào lọ bù được thì gộp vào kế hoạch của mục 5, không hiện hai thẻ. Thông báo dùng cùng câu này.
  4. **Thẻ tín dụng đến hạn** (trong 5 ngày): trả đủ dư nợ để không mất lãi; trả thẻ không đụng lọ vì lọ đã trả lúc quẹt.
  5. **Tiền chưa chia vào lọ** (kế hoạch a–d, cũng dùng cho ngày lương):
     a. Thiết yếu đủ cho hoá đơn đến hạn trước kỳ lương tới + chi tiêu thiết yếu đến lúc đó (trung bình tháng thiết yếu từ lịch sử 3 tháng, chưa có lịch sử thì % Thiết yếu × lương; trừ phần hoá đơn; nhân số ngày / 30), bù luôn nếu Thiết yếu đang âm;
     b. bù các lọ âm khác;
     c. quỹ khẩn cấp: Tiết kiệm hướng tới 3 tháng chi tiêu thiết yếu (3–6, bắt đầu 3); chưa đủ thì nhận một nửa phần còn lại;
     d. phần còn lại chia theo %.
     Nếu các lọ đang giữ nhiều hơn ví thì phần thiếu đó để lại chưa chia trước.
     **Số tròn:** mỗi phần làm tròn lên bước gọn (dưới 1tr: 10k, dưới 10tr: 50k, từ 10tr: 100k; tiền tệ khác: hai chữ số đầu), Tiết kiệm (hoặc lọ cuối) nhận phần chênh để tổng vẫn đúng. Bù lọ âm cũng dùng số tròn khi lọ nguồn đủ. Dòng "vì sao" bỏ phần bằng 0.
  6. **Hoá đơn đến hạn** hôm nay/ngày mai.
  7. **Tiêu nhanh:** lọ đã dùng ≥ 50% và nhanh hơn tháng ≥ 30 điểm (ví dụ 80% khi tháng mới qua 40%) → mức tiêu mỗi ngày đến cuối tháng = số dư / số ngày còn lại.
  8. **Cuối tháng** (3 ngày cuối): Hưởng thụ còn dư → giữ lại hay chuyển sang Tiết kiệm?
  9. **Sau 2–3 tháng:** so % Thiết yếu với chi thực tế trên thu nhập; lệch ≥ 5 điểm thì gợi ý % mới (làm tròn 5, trong 30–80%), phần chênh lấy từ / trả về Hưởng thụ rồi Phát triển.
  10. **Mua tài sản hay khoản chi lớn** (≥ 1/3 lương, trong chat): kiểm tra quỹ khẩn cấp trước.
- **Hiện ở đâu:** một thẻ "Moonee gợi ý" đầu tab Ngân sách (và câu ghi chú ở Tổng quan cùng nội dung); tin nhắn trong chat sau khoản chi làm lọ âm; thông báo ngày lương và lọ âm (dùng `Reminders`). Tối đa **2 gợi ý mỗi ngày**; cảnh báo (ngày lương, ví chưa có tiền, lọ âm, thẻ, hoá đơn) luôn hiện.
- **Học:** bỏ qua cùng một loại gợi ý hai lần thì Moonee thôi gợi ý loại đó; Tài khoản → Mức hỗ trợ của Moonee có nút hiện lại.
- **Đầu tư:** chỉ nguyên tắc và giới hạn rủi ro (quỹ khẩn cấp trước, chỉ đầu tư tiền 3–5 năm không dùng, phân tán, không vay để đầu tư), luôn kèm "Moonee không phải chuyên gia tư vấn đầu tư có giấy phép". Không bao giờ bảo nên mua gì.
- **Trợ lý:** skill `jar-budgeting`, `spending-coach`, `close-management` đọc `advice` của `monthBudget` và nói lại đúng số; `monthClose` gợi ý bù lọ âm theo cùng thứ tự.

## 5. Quan tâm

- **Watchlist:** giá vàng SJC/PNJ, bạc, cổ phiếu VN, tỷ giá USD, crypto (tuỳ chọn).
- **Tài sản đang giữ:** "2 lượng SJC", "500 cổ FPT", "1000 USD" → định giá theo giá hiện tại.
- **Net worth** = số dư các ví + tài sản − nợ (thẻ tín dụng, sổ nợ). Có biểu đồ theo thời gian.
- **Cảnh báo giá** theo ngưỡng (ví dụ SJC trên 90tr/lượng).
- ⚠️ **Cần chốt nguồn dữ liệu** và điều khoản sử dụng: giá vàng (SJC/PNJ công bố trên web), cổ phiếu VN (API của công ty chứng khoán hoặc bên cung cấp dữ liệu), tỷ giá. Vì app mua đứt và không có server, nên xem xét có cần một backend nhỏ hay proxy để cache giá không.

## 6. Tài khoản / Cài đặt

### 6.1 Cơ bản
- **Ngôn ngữ** (xem mục 10), hồ sơ, định dạng số, ngày bắt đầu tuần/tháng tài chính
- **Tiền tệ mặc định:** tự nhận theo vùng của máy (máy để vùng Việt Nam thì là VND), user đổi được
- Danh mục và lọ, quản lý ví
- Mức nhắc nhở, giờ "không làm phiền"
- **Mức hỗ trợ của Moonee** (Tự động / Gợi ý / Tự làm, mục 4.6) và nút hiện lại các gợi ý đã bỏ qua

### 6.2 Trợ lý Moonee
- **Chế độ AI:** Model local / BYOK / Lai (xem mục 9.1). Mặc định cho user mới: Model local; chưa tải model thì Cài đặt ghi rõ "Chưa tải model, Moonee dùng bộ đọc cơ bản" kèm nút Quản lý model.
- **Kết quả kiểm tra** (Kiểm tra key, Kiểm tra kết nối): cùng một kiểu dòng, biểu tượng SF Symbol ở cột icon (đang kiểm tra: vòng xoay; được: dấu tích xanh; lỗi: dấu X đỏ) rồi câu thân thiện ("Kết nối được."). Không emoji trong giao diện.
- **Model local:** danh sách model, tải về, xoá (xem mục 9.2)
- **BYOK:** chọn nhà cung cấp, nhập API key (lưu trong Keychain), chọn model
- **Skill:** bật/tắt từng skill tài chính của trợ lý (xem mục 9.4)
- **Nâng cao** (cho power user): import skill tự viết (.md), sửa skill có sẵn (có khôi phục mặc định), prompt tuỳ chỉnh
- **BYOK:** OpenRouter, DeepSeek, OpenAI, Anthropic, Gemini, Custom (OpenAI-compatible); danh sách model lấy theo key, có tìm kiếm
- Hiện rõ dữ liệu nào được gửi lên cloud (chỉ khi dùng BYOK)

### 6.3 Dữ liệu
- **Import CSV/Excel:** có màn ghép cột, AI tự đoán cột và danh mục. Dùng cho sao kê ngân hàng và cho dữ liệu chuyển từ app khác (Money Lover, Misa, Excel).
- **Export CSV**
- **Sao lưu, đồng bộ iCloud** (CloudKit, private database)
- **Xoá toàn bộ dữ liệu** (trên máy + iCloud), có xác nhận hai bước

### 6.4 Bảo mật
- Khoá app bằng Face ID/passcode (khi mở và khi quay lại từ nền sau N phút)
- Ẩn số dư (chạm để hiện/ẩn)
- Che nội dung trong App Switcher

### 6.5 Khác
- Hỗ trợ / góp ý, Giới thiệu, chính sách quyền riêng tư, đánh giá app
- Giới thiệu có dòng **Điều khoản & miễn trừ trách nhiệm**: toàn văn `docs/TERMS.md` (ngày user đã đồng ý ở cuối).

## 7. Onboarding (qua chat)

00. **Điều khoản** (màn riêng, trước mọi bước, không bỏ qua được): thẻ tóm tắt các ý chính (công cụ ghi chép và ngân sách, không phải chuyên gia tư vấn; AI có thể sai và chỉ phân tích số user nhập; không khuyên mua bán đầu tư, không dự đoán giá; user tự chịu trách nhiệm, nhà phát triển app, bên làm model AI và nhà cung cấp AI không chịu trách nhiệm; dữ liệu ở máy và iCloud của user, BYOK thì tin nhắn đi tới nhà cung cấp user chọn), link đọc toàn văn, ô "Tôi từ 18 tuổi trở lên và đồng ý…" bắt buộc, nút "Tôi đồng ý" chỉ bật khi đã tick. Lưu phiên bản đã đồng ý + ngày (`Terms.version`). Khi `Terms.version` tăng, user cũ thấy lại màn này lúc mở app ("Moonee đã cập nhật điều khoản").
0. **Thiết lập hồ sơ** (màn riêng, không phải chat): tên hiển thị + chọn avatar có sẵn, chỉ lưu trên máy, không đăng nhập. Có nút "Để sau".
1. Moonee chào và giới thiệu ngắn (nhân vật xuất hiện).
2. Hỏi thu nhập hằng tháng (khoảng) và cố định hay không đều, rồi **ngày nhận lương**. Có ngày thì tạo khoản thu định kỳ (mục 4.3), ngày nhận đầu tiên là sau hôm nay (tiền đã nhận nằm trong số dư ví ở bước 3).
3. Hỏi các ví đang dùng, số dư ban đầu (bỏ qua được).
4. Hỏi các hoá đơn cố định.
5. Đề xuất % cho các lọ. User chấp nhận hoặc chỉnh. Số dư ví **không tự chia**: nằm ở Chưa chia vào lọ để user quyết một lần ở tab Ngân sách (mục 4.1; Tự động thì Moonee áp dụng kế hoạch).
5b. Chọn **mức hỗ trợ của Moonee**: Gợi ý (mặc định), Tự động hoặc Tự làm (mục 4.6).
6. Chọn chế độ AI (gợi ý theo đời máy) và mức nhắc nhở.
7. Bật Face ID (tuỳ chọn) và xin quyền thông báo.

Mục tiêu: xong trong 1–2 phút, bước nào cũng bỏ qua được.

## 8. Widget và Lock Screen
- Widget nhỏ: nút (+) nhập nhanh và số còn lại hôm nay
- Widget vừa: các lọ + hoá đơn sắp tới
- Lock Screen: nút nhập nhanh, số dư lọ chính
- Widget mở thẳng vào chat Moonee bằng deep link.
- ⚠️ Widget phải tôn trọng "ẩn số dư" vì màn hình khoá ai cũng nhìn thấy.

## 9. Trợ lý AI: model và skill

### 9.1 Các chế độ AI
Moonee không có server AI và không trả phí LLM thay user.

| Chế độ | Chạy ở đâu | Ghi chú |
|---|---|---|
| **Model local** (mặc định) | Model mở (Gemma, Qwen, Bonsai...) tải về và chạy trên máy, giống app Locally | Riêng tư, offline, miễn phí. Chạy qua MLX Swift. Chưa tải model thì dùng bộ parse quy tắc (vẫn chạy offline) |
| **BYOK** | Cloud, bằng API key của user (OpenAI / Anthropic / Gemini...) | Thông minh nhất, cần mạng |
| **Lai** | Giao dịch đọc trên iPhone bằng model local (chưa có thì bằng quy tắc), tư vấn và báo cáo bằng BYOK | Cân bằng giữa riêng tư và chất lượng |
| *Fallback* | Bộ parse quy tắc (regex + từ điển) | Khi không có model nào dùng được. Vẫn nhập được giao dịch; báo cáo chỉ gồm số liệu và biểu đồ |

Apple Foundation Models không dùng (quyết định 06/11: không chạy ổn trên máy owner, model local là đủ). Cài đặt cũ chọn Apple được chuyển sang Model local.

### 9.2 Quản lý model local
- **Danh mục model** có sẵn trong app (do Moonee chọn lọc và kiểm tra trước). Mỗi model ghi: dung lượng tải, RAM cần, tốc độ ước tính, mức hỗ trợ tiếng Việt, có đọc được ảnh không.
- **Gợi ý model theo đời máy** (dựa vào RAM). Máy yếu thì gợi ý model nhỏ hoặc BYOK.
- Tải model khi user chọn (từ Hugging Face): có tuỳ chọn chỉ tải qua Wi-Fi, tải tiếp khi bị ngắt, xoá model để giải phóng bộ nhớ.
- **Không đóng gói model trong app** để app nhẹ khi tải từ App Store.
- ⚠️ **Lưu ý kỹ thuật:**
  - **RAM:** máy 6–8GB chạy được model khoảng 1–4B (lượng tử 4-bit). Cần entitlement `com.apple.developer.kernel.increased-memory-limit`.
  - **Pin và nhiệt:** chỉ nạp model khi cần, giải phóng khi app vào nền.
  - **Output có cấu trúc:** parse giao dịch cần JSON đúng schema. Dùng sinh có ràng buộc (JSON schema / grammar) và kiểm tra lại; nếu sai thì chuyển sang bộ parse quy tắc.
  - **License:** kiểm tra license từng model trước khi đưa vào danh mục (Gemma có điều khoản sử dụng riêng).
  - **Tiếng Việt:** chọn model trong danh mục theo mức hỗ trợ tiếng Việt (Gemma, Qwen xử lý tốt).

### 9.3 Phân vai giữa các model
| Việc | Model nhỏ (local) | BYOK |
|---|---|---|
| Parse giao dịch từ text/voice | ✓ | ✓ |
| Đọc ảnh hoá đơn | OCR bằng Vision framework, đưa chữ cho model (hoặc model có vision) | ✓ (đọc ảnh trực tiếp) |
| Hỏi đáp ngắn ("tháng này ăn uống hết bao nhiêu?") | ✓ | ✓ |
| Báo cáo, lời khuyên dài, phân tích chênh lệch | Bản rút gọn: app tính số, model viết nhận xét ngắn | ✓ đầy đủ |

**Nguyên tắc: mọi con số do app tính.** Model không tự cộng trừ mà gọi tool (hàm Swift) để lấy số liệu, rồi chỉ diễn giải. Cách này tránh AI tính sai tiền.

### 9.4 Skill tài chính (dựa trên bộ Finance của Anthropic)
Bộ Finance (repo `anthropics/knowledge-work-plugins`, thư mục `finance`) có 8 skill và 6 connector, **viết cho kế toán doanh nghiệp**. Mỗi phần được xử lý như sau:

| Skill gốc | Dùng cho Moonee? | Chuyển thành |
|---|---|---|
| `reconciliation` | ✓ | Đối chiếu sao kê import với giao dịch đã ghi: tìm khoản thiếu, trùng, lệch số dư ví |
| `variance-analysis` | ✓ | So sánh thực tế với ngân sách theo lọ/danh mục và giải thích vì sao chênh |
| `close-management` | ✓ | "Chốt sổ cuối tháng": checklist cuối tháng, cộng dồn lọ, gợi ý cân đối lọ, tạo báo cáo tháng |
| `financial-statements` | ✓ | Báo cáo thu–chi cá nhân, bảng tài sản (net worth), dòng tiền |
| `journal-entry`, `journal-entry-prep` | Một phần | Lấy ý tưởng "mỗi giao dịch có nguồn và đích" (ví/lọ) để không tính hai lần (thẻ tín dụng, chuyển ví, cho vay) |
| `audit-support`, `sox-testing` | ✗ | Chỉ dành cho doanh nghiệp, bỏ |
| 6 connector (BigQuery, Databricks, Snowflake, Gmail, Calendar, Slack) | ✗ | Bỏ |

**Skill riêng Moonee cần tự viết:**
- `transaction-parser`: hiểu cách nói tiền và ngày theo từng ngôn ngữ
- `jar-budgeting`: chia thu nhập, cân đối 6 lọ
- `goal-planning`: lập kế hoạch tiết kiệm cho mục tiêu
- `bill-reminder`: khoản định kỳ, thẻ tín dụng
- `debt-tracking`: sổ nợ
- `spending-coach`: nhắc nhở và khích lệ theo giọng Moonee
- `local-finance-context`: bối cảnh từng nước (VN: giá vàng SJC, lãi tiết kiệm, thói quen chi tiêu)

**Cách chạy skill trong app:**
- Skill gốc viết cho môi trường của Claude (đọc file, chạy script). Trong Moonee, mỗi skill gồm: **một file hướng dẫn** (markdown, có bản cho từng ngôn ngữ) và **danh sách tool Swift** mà skill được gọi, ví dụ `getTransactions(range)`, `jarBalances()`, `budgetVsActual(period)`.
- Script Python trong skill gốc không chạy được trên iOS, nên phần tính toán được viết lại bằng Swift dưới dạng tool.
- **Nạp skill theo nhu cầu:** Moonee nhận diện ý định (hỏi báo cáo, chốt tháng...) rồi mới nạp hướng dẫn của skill đó vào prompt. Cách này tiết kiệm context, rất quan trọng với model local.
- Skill chạy được với mọi model (local / BYOK), không phụ thuộc Claude. Model nhỏ dùng bản hướng dẫn rút gọn.
- ⚠️ Kiểm tra license của repo `knowledge-work-plugins` trước khi đưa nội dung vào app bán thương mại, và ghi credit nếu license yêu cầu.

## 10. Ngôn ngữ

### 10.1 Ngôn ngữ hỗ trợ
| Ngôn ngữ | Mã | Ghi chú |
|---|---|---|
| English | `en` | **Mặc định**, cũng là ngôn ngữ dự phòng khi thiếu bản dịch |
| Tiếng Việt | `vi` | |
| ภาษาไทย (Thai) | `th` | Tiền mặc định THB khi vùng là Thái Lan |
| ພາສາລາວ (Lao) | `lo` | iOS không có tiếng Lào làm ngôn ngữ hệ thống; Speech chưa có tiếng Lào nên giọng nói dùng tiếng Thái và Moonee báo cho user |

Ngôn ngữ khác thêm theo checklist ở mục 10.6. Tiếng Thái và tiếng Lào không có dấu cách giữa các từ: bộ parse tách từ bằng từ điển hệ thống (ICU) cho cả câu nhập lẫn từ khoá.

### 10.2 Cách chọn ngôn ngữ
- Mặc định theo ngôn ngữ hệ thống iOS. Nếu hệ thống dùng ngôn ngữ chưa hỗ trợ thì về English.
- User đổi được trong **Tài khoản → Ngôn ngữ**: danh sách trong app (Giống iPhone / English / Tiếng Việt / ไทย / ລາວ), ghi `AppleLanguages` của riêng app, mở lại app là đổi. Không dùng trang per-app của Cài đặt iOS vì trang đó chỉ hiện ngôn ngữ đã thêm vào iPhone, còn tiếng Lào không phải ngôn ngữ hệ thống của iPhone.
- **Ngôn ngữ giao diện tách khỏi tiền tệ và định dạng.** Ví dụ: giao diện English nhưng tiền vẫn là VND.
- **Tiền tệ** tự nhận theo vùng của máy (`Locale.current.currency`), user đổi được trong Cài đặt.
- Cách hiểu tiếng lóng tiền phụ thuộc tiền tệ: "45k" với VND là 45.000 ₫, với USD là $45,000. Bộ parse phải biết tiền tệ hiện tại.

### 10.3 Kiến trúc để thêm ngôn ngữ dễ dàng
- Toàn bộ chuỗi giao diện nằm trong **String Catalog** (`Localizable.xcstrings`), không hard-code chữ trong code. Widget và thông báo cũng vậy.
- Số, ngày, tiền tệ format bằng `FormatStyle` theo `Locale`, không tự ghép chuỗi kiểu `"\(amount)đ"`.
- Số nhiều (plural) dùng tính năng plural của String Catalog ("1 transaction" / "3 transactions").
- **Dữ liệu lưu bằng key, không lưu chữ đã dịch:** danh mục và lọ mặc định lưu `key` (ví dụ `jar.essentials`), hiển thị theo ngôn ngữ hiện tại. Tên do user tự đặt thì giữ nguyên như user nhập.
- Những gì riêng cho từng ngôn ngữ được gom vào **một thư mục cho mỗi ngôn ngữ**:
  - Từ điển parse quy tắc: từ khoá danh mục, tiếng lóng tiền (`k`, `củ`, `lít` / `k`, `grand`), từ chỉ ngày ("hôm qua" / "yesterday")
  - Prompt hệ thống và giọng văn của trợ lý
  - Các mẫu thông báo và microcopy của Moonee

### 10.4 AI và ngôn ngữ
- **Nhập** bằng ngôn ngữ nào cũng được, không phụ thuộc ngôn ngữ giao diện. Ví dụ đang để giao diện English vẫn gõ "phở 45k" được.
- **Moonee trả lời** theo ngôn ngữ giao diện (có thể thêm tuỳ chọn trả lời theo ngôn ngữ user vừa gõ).
- Voice: chọn locale cho Speech theo ngôn ngữ giao diện, có tuỳ chọn đổi riêng.
- Mỗi model hỗ trợ ngôn ngữ ở mức khác nhau, nên danh mục model local cần ghi rõ mức hỗ trợ tiếng Việt (mục 9.2).

### 10.5 Import / Export
- File CSV export dùng **tên cột tiếng Anh cố định** (`date, amount, category, ...`) để import lại được bất kể ngôn ngữ.
- Màn ghép cột khi import nhận được tên cột của nhiều ngôn ngữ ("Ngày", "Date", "Số tiền", "Amount"...).

### 10.6 Checklist khi thêm một ngôn ngữ mới
1. Thêm ngôn ngữ vào String Catalog và dịch các chuỗi.
2. Thêm thư mục ngôn ngữ: từ điển parse, prompt, microcopy.
3. Dịch tên danh mục và lọ mặc định (theo key).
4. Kiểm tra font hiển thị đủ dấu và ký tự.
5. Kiểm tra layout với chuỗi dài, và với ngôn ngữ viết phải sang trái (RTL) nếu có.
6. Dịch metadata trên App Store (tên, mô tả, ảnh chụp màn hình).

---

## 11. Mô hình dữ liệu (phác thảo)

```
Wallet        (id, name, type: cash|bank|ewallet|credit|savings|investment, balance, creditLimit?, statementDay?, dueDay?, inBudget)
Jar           (id, key?, customName?, icon, color, percent, balance, order)   // key cho lọ mặc định, customName cho lọ user đặt
Category      (id, key?, customName?, icon, jarId, kind: expense|income)
Transaction   (id, date, amount, kind: expense|income|transfer|jarTransfer|lend|borrow|repay,
               walletId, toWalletId?, categoryId?, jarId?, note, source: text|voice|image|import|manual,
               attachment?, debtId?)
IncomeSplit   (transactionId, jarId, amount)          // cách chia của từng khoản thu, hoặc của một lần chia tiền chưa chia vào lọ
Recurring     (id, name, amount, isEstimate, rule, nextDue, remindDaysBefore, walletId, categoryId)   // danh mục thu = khoản thu định kỳ (lương)
Goal          (id, name, target, deadline, jarId, saved)
Debt          (id, person, direction: lent|borrowed, amount, remaining, dueDate?)
Asset         (id, symbol, kind: gold|silver|stock|fx|crypto, quantity, costBasis?)
WatchItem     (id, symbol, kind, alertAbove?, alertBelow?)
MerchantRule  (pattern, categoryId)                    // học từ các lần user sửa
```

---

## 12. Lộ trình

**MVP**
- Đa ngôn ngữ: English + Tiếng Việt, String Catalog ngay từ dòng code đầu tiên
- Chat nhập text/voice/ảnh, thẻ sửa/hoàn tác, học từ lần sửa
- AI: 1–2 model local đã kiểm tra tiếng Việt + BYOK + fallback parse theo quy tắc
- Skill: `transaction-parser`, `jar-budgeting`, `close-management` (chốt sổ và báo cáo tháng), `spending-coach`
- Tổng quan + sổ giao dịch
- Ví (kể cả thẻ tín dụng), lọ envelope, chia thu nhập theo từng khoản
- Khoản định kỳ + nhắc nhở (3 mức)
- Báo cáo tháng
- Onboarding qua chat
- Face ID, ẩn số dư, che App Switcher, xoá dữ liệu
- iCloud sync, export CSV

**Bản 2**
- Mục tiêu
- Sổ nợ
- Báo cáo tuần/năm
- Widget + Lock Screen
- Import CSV/Excel + skill `reconciliation` (đối chiếu sao kê)
- Quan tâm: watchlist, tài sản, net worth, cảnh báo giá + skill `financial-statements`
- Skill `variance-analysis`, `goal-planning`, `debt-tracking`
- Mở rộng danh mục model local; import skill tự viết

**Để sau**
- Liên kết ngân hàng qua Open API
- Siri/Shortcuts, Share Sheet
- Ngân sách gia đình/chia sẻ, chia bill

⚠️ Thứ tự trên là đề xuất. Nếu bạn muốn đưa Sổ nợ hoặc Widget vào MVP thì cứ kéo lên.

---

# Lưu ý cho Design System

Bạn đã có thiết kế, màu (xanh lá/mint + vàng) và nhân vật. Dưới đây là checklist để soát lại bộ design trước khi code.

## A. Màu sắc
- Bảng màu thương hiệu và màu ngữ nghĩa (thu/chi/cảnh báo) đã có trong bộ thiết kế.
- [ ] **Chỉ light mode:** khoá giao diện sáng bằng `UIUserInterfaceStyle = Light` trong Info.plist, để iOS không tự đảo màu khi máy bật dark mode. Widget phải tự chỉ định màu nền, không dùng màu hệ thống.
- [ ] **Bảng màu cho lọ:** 6 lọ mặc định và các lọ user tự thêm cần một bảng màu phân loại (khoảng 10–12 màu) đủ khác nhau, kể cả với người mù màu, và không trùng màu ngữ nghĩa.
- [ ] Định nghĩa màu thành **token** (`brand.primary`, `semantic.expense`, `jar.1...`), đừng hard-code mã hex trong màn hình.

## B. Chữ và số
- [ ] Số tiền dùng **tabular figures** (chữ số đều độ rộng) để các cột không bị nhảy.
- [ ] Format VND thống nhất: đầy đủ `1.250.000 ₫`, rút gọn `1,25tr` / `850k` (chốt quy tắc cho từng chỗ).
  - **Quy tắc (UI review 2026-11):** mặc định dùng số **đầy đủ**, kể cả trong danh sách và thẻ (`199.000 ₫`, `3.250.000 ₫ / 5.500.000 ₫`). Chỉ **rút gọn** ở tâm biểu đồ (ring, donut) và ô nhỏ hẹp hơn 90 pt (ví dụ ô lọ 4 cột ở Tổng quan). Số không vừa thì thu nhỏ chữ (`minimumScaleFactor`), không chuyển sang rút gọn.
- [ ] **Thang chữ:** màn hình chỉ dùng token trong `Theme.swift` (`screenTitle` 20, `headerPill` 13, `heroAmountFont()` 26, `cardAmount` 20, `greeting` 17, `sectionTitle` 16, `rowTitle` 15, `bodyText` 15, `secondaryText` 13, `caption` 12, `chip` 13), không dùng `.system(size:)` cho chữ.
- [ ] Trạng thái **ẩn số dư**: `*****` có độ rộng cố định.
- [ ] Hỗ trợ **Dynamic Type**: số lớn trên dashboard vẫn phải vừa khung khi chữ to.
- [ ] Font hiển thị đúng dấu tiếng Việt (ă, ơ, ư, ệ...), nhất là font display hoặc font tròn trang trí.
- [ ] Layout chịu được độ dài chữ khác nhau giữa các ngôn ngữ: nút và nhãn không bị cắt, không cố định độ rộng theo chữ tiếng Anh. Kiểm tra bằng pseudo-localization trong Xcode.

## C. Animation và gradient
- [ ] Tôn trọng **Reduce Motion**: tắt hoặc giảm hiệu ứng khi user bật trong cài đặt iOS.
- [ ] Animation số tiền (đếm lên) nên ngắn (<0,6s). Đừng để user phải chờ mới đọc được số.
- [ ] Mỗi màn hình chỉ nên có một vùng gradient chính để giữ được điểm nhấn.
- [ ] Haptic: nhẹ khi lưu giao dịch, rõ hơn khi đạt mục tiêu, cảnh báo khi vượt lọ.

## D. Nhân vật Moonee (chiếc ví xanh): các trạng thái cần có
- [ ] Đồng xu nhân vật đang cầm có ký hiệu **₫**. Khi user dùng tiền tệ khác VND (giao diện English, user nước ngoài), cần một phiên bản đồng xu trung tính (ngôi sao, mặt trăng...) hoặc đổi theo tiền tệ.

| Trạng thái | Dùng ở đâu |
|---|---|
| Chào / idle | Onboarding, chat trống |
| Đang nghe | Khi bấm mic |
| Đang nghĩ | Đang parse hoặc gọi AI |
| Vui / đã lưu | Lưu giao dịch xong |
| Khen / ăn mừng | Đạt mục tiêu, chi dưới ngân sách |
| Lo lắng | Lọ chạm 80% hoặc vượt |
| Buồn ngủ | Empty state, nhắc ghi chép buổi tối |
| Lỗi / bối rối | AI không hiểu, mất mạng |
- [ ] Có phiên bản **icon nhỏ** (cho nút (+) giữa tab bar, avatar chat, widget) và phiên bản **đầy đủ** (onboarding, báo cáo).
- [ ] Nhân vật còn rõ ở kích thước 24–28pt trong tab bar.

## E. Component cần thiết kế
- [ ] Tab bar với nút (+) logo nổi ở giữa (kèm trạng thái nhấn)
- [ ] Ô nhập chat: text + mic + camera/ảnh, trạng thái đang ghi âm
- [ ] **Thẻ giao dịch** trong chat: bình thường / đang sửa / đã hoàn tác / nhiều giao dịch gộp. Hiển thị thống nhất "Danh mục · Lọ" (ví dụ "Sách · Phát triển bản thân")
- [ ] Bong bóng chat Moonee và user, thẻ báo cáo trong chat, gợi ý trả lời nhanh
- [ ] Thẻ lọ: bình thường / ≥80% / vượt / âm
- [ ] Thẻ hoá đơn: sắp đến hạn / hôm nay / quá hạn / đã trả
- [ ] Thẻ mục tiêu, thẻ nợ, thẻ tài sản/giá (tăng/giảm)
- [ ] Biểu đồ: donut (theo lọ), cột (theo thời gian), đường (net worth). Vòng % ngân sách đổi màu theo mức (bình thường / ≥80% / vượt)
- [ ] Màn khoá Face ID, lớp che App Switcher
- [ ] Empty state cho từng màn, skeleton khi tải, trạng thái lỗi/offline
- [ ] Widget: nhỏ, vừa, Lock Screen (tròn/chữ nhật/inline), kèm trạng thái ẩn số dư

## F. Accessibility
- [ ] Vùng chạm tối thiểu 44×44pt
- [ ] Nhãn VoiceOver cho số tiền: đọc thành "một triệu hai trăm năm mươi nghìn đồng", không đọc "1.250.000"
- [ ] Không truyền đạt thông tin chỉ bằng màu (thu/chi cần thêm dấu +/− hoặc icon)

## G. Giọng văn "Moonee – Bạn"
- [ ] Moonee tự xưng "Moonee", gọi user là "bạn". Ví dụ: "Moonee đã ghi 45k phở cho bạn rồi nè!"
- [ ] Bản English giữ cùng tính cách (thân thiện, khích lệ). Ví dụ: "Got it! Moonee logged 45k for phở 🍜". Viết lại cho tự nhiên với từng ngôn ngữ, không dịch máy từng câu.
- [ ] Nhắc chi tiêu theo hướng **khích lệ, không phán xét**: "Lọ Hưởng thụ còn 200k, bạn cân nhắc chút nha" thay vì "Bạn đã tiêu quá nhiều".
- [ ] Viết sẵn bộ microcopy cho thông báo, lỗi và empty state để giọng văn đồng nhất.