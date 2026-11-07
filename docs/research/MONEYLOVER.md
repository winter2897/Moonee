# Học từ Money Lover: logic Ngân sách và Sổ giao dịch

> Nghiên cứu ngày 07/11/2026 (session s23). Chỉ là tài liệu, chưa đổi code.
> Moonee được đọc từ code trên `main` (`ecd969b`, Build 4), không chỉ từ spec. Hai việc đang làm song song **không** đề xuất lại ở đây: **Sổ nợ** (s19, branch `claude/s19-debt-book-27d2e9`) và **lịch chi tiêu** ở Tổng quan (s20, branch `claude/s20-spending-calendar-e2bfcc`).
> Nguồn Money Lover (viết tắt ML) ghi trong ngoặc vuông, ví dụ [H16]. Danh sách link ở cuối. [H…] là trung tâm trợ giúp chính thức (91 bài, đọc qua API công khai của Zendesk vì trang web chặn bot). [A…] là hướng dẫn chính thức cũ (bản lưu trên Wayback Machine, ứng với các phiên bản trước). [T…] là nguồn bên thứ ba. Chỗ nào chưa kiểm chứng được thì ghi **chưa kiểm chứng**.

---

## 0. Tóm tắt cho owner

1. **ML và Moonee hiểu "ngân sách" khác hẳn nhau.** Ngân sách của ML chỉ là **hạn mức chi**: một hoặc nhiều danh mục × một ví (hoặc Tổng) × một kỳ. Nó không giữ tiền, không gắn với thu nhập và không cộng dồn sang kỳ sau [H16][H17]. Lọ của Moonee là **phong bì có tiền thật** và cộng dồn qua các tháng. Lọ là bản sắc và là điểm mạnh của Moonee: user ML than ngân sách "vô dụng nếu muốn giữ đúng ngân sách" và muốn có kiểu "reset mỗi tháng" [T3][H44]. **Giữ lọ.** Cái Moonee thiếu là lớp **hạn mức theo danh mục** nằm *bên trong* lọ (ví dụ "Ăn uống tối đa 3tr/tháng" trong lọ Thiết yếu).
2. **Vì sao Ngân sách của Moonee "chưa đúng":** code hiện có **ba luật khác nhau cho tiền vào**, và **chi tiêu không thuộc lọ nào lặng lẽ ăn vào Chưa chia vào lọ**. Hệ quả là con số trên tab không khớp với điều user nghĩ (mục 3.1). Đây là việc P0, chủ yếu sửa logic, gần như không đổi model.
3. **Sổ giao dịch của Moonee còn quá sơ sài** so với ML. Mặc định đang mở "Toàn bộ thời gian". Không có tab theo tháng, không có dòng tổng Tiền vào / Tiền ra / Chênh lệch, không xem theo danh mục, không xem số dư đầu kỳ / cuối kỳ của một ví, không có mục "Sắp tới". Cũng là P0.
4. **Bài học từ chỗ ML làm user rối:** ML tính chuyển ví thành *hai* giao dịch (một chi, một thu) rồi phải thêm cờ "Không tính vào báo cáo" để khỏi bị đếm đôi. Dòng Tiền vào / Tiền ra ở đầu sổ lại *có* tính những khoản bị loại đó, còn báo cáo thì *không* [H3][H21][H26]. Moonee đã làm đúng hơn: một giao dịch chuyển, không bao giờ là thu hay chi. **Đừng copy** mô hình hai giao dịch của ML. Chỉ lấy cờ "Không tính vào báo cáo" cho các trường hợp hiếm (tiền chi hộ, công tác phí sẽ được hoàn).
5. **Nên lấy về (P1):** điều chỉnh số dư bằng một giao dịch thay vì sửa lịch sử [H5], khoản định kỳ tự ghi khi đến ngày, "mỗi ngày còn tiêu được" và dự báo cuối tháng [H19][A16], cờ "Không tính vào báo cáo".
6. **Không nên học:** khoản định kỳ của ML chỉ bắt đầu từ kỳ *sau* (user tưởng là lỗi) [H12][H13][T1], định kỳ không đồng bộ giữa các máy, công tắc toàn cục "Không tính báo cáo" làm đổi nghĩa mọi con số [A2], và việc chặn tính năng sau paywall.
7. Kết thúc tài liệu là bảng **6 session** có thể giao ngay (mục 6).

---

## 1. Money Lover hoạt động thế nào

### 1.1 Ví
- **Các loại ví:**
  - **Ví thường**: nhập tay.
  - **Ví liên kết ngân hàng**: chỉ đọc, đồng bộ mỗi 6–8 giờ, là gói thuê bao riêng ngoài Premium [H1][H39][H41].
  - **Ví tín dụng**: có hạn mức, ngày sao kê, ngày đến hạn. Số dư âm [H2][H4].
  - **Ví mục tiêu**: có số tiền mục tiêu và hạn chót, không tính lãi [H2][H28].
  - **Ví chia sẻ**: luôn bị loại khỏi Tổng với thành viên, và ngân sách không được chia sẻ [H6].
- **"Tổng" (Total Wallet):** là tổng số dư các ví bật "tính vào tổng". Thẻ tín dụng cộng số âm [H1]. Ví "không tính vào tổng" biến mất khỏi sổ và báo cáo ở chế độ Tổng [H2], và không tính vào ngân sách theo Tổng [H17]. ML khuyên loại ví mục tiêu ra nếu đó là tiền để dành không tiêu [H1]. Ý này giống "Tính vào ngân sách" của Moonee.
- **Chuyển ví:** tạo **hai giao dịch** (chi "Chuyển đi" ở ví nguồn, thu "Chuyển đến" ở ví đích), hoặc **ba** nếu có phí. Mặc định bật "không tính vào báo cáo", user tắt được cho từng lần [H3]. Cũng có thể đổi danh mục của lần chuyển.
- **Điều chỉnh số dư:** user nhập số dư thật. App tạo một khoản thu hoặc chi bằng phần chênh, mặc định không tính vào báo cáo [H5]. ML khuyên *không* "về 0 mỗi tháng" vì làm sai báo cáo [H5].
- **Lưu trữ / xoá ví:** ví lưu trữ thì đóng băng, không chọn được khi nhập. Xoá ví thì xoá luôn mọi giao dịch, không khôi phục được [H2].
- **Tiền tệ:** mỗi ví một loại tiền. Giao dịch nhập bằng tiền khác được **đổi sang tiền của ví ngay lúc nhập** [H7]. Tổng gộp nhiều loại tiền theo tỷ giá nào thì **chưa kiểm chứng**.

### 1.2 Giao dịch và danh mục
- **Ba nhóm danh mục:** Chi, Thu, **Nợ/Cho vay** [H8].
  - Danh mục có **cha – con** (ví dụ Ăn uống → Cà phê) [H9].
  - Từ v8, danh mục là **dùng chung** cho mọi ví, mỗi ví bật/tắt từng danh mục được [H11][H43].
  - Có chức năng **gộp danh mục** (không hoàn tác được) [H9].
- **Danh mục cố định không xoá được:** Chuyển đi, Chuyển đến, Trả lãi, Thu lãi, Chưa phân loại, và bốn danh mục nợ: Cho vay, Đi vay, Trả nợ, Thu nợ [H10].
- **Trường mở rộng của giao dịch:**
  - Với ai, vị trí, sự kiện, nhắc nhở, một ảnh.
  - **Không tính vào báo cáo**: giao dịch vẫn đổi số dư, nhưng không vào báo cáo, ngân sách hay màn Tổng quan. Trong báo cáo nó nằm ở mục "Khác" [H7][H25].
- **Gợi ý danh mục:** cùng một số tiền ≥ 3 lần ở cùng danh mục và ví thì lần sau tự gợi ý. Ghi chú cũ cũng được gợi ý lại [H7].
- **Nhân bản giao dịch:** có [H15]. **Xoá nhiều cùng lúc:** có, không khôi phục được [H7].
- **Sự kiện và Chế độ du lịch:** gắn sự kiện (chuyến đi) để biết tổng chi. Khi bật Chế độ du lịch, mọi giao dịch mới tự gắn sự kiện đó [H14].
- **Giao dịch định kỳ và hoá đơn:**
  - **Định kỳ**: số tiền cố định, tự ghi khi đến ngày [H12].
  - **Hoá đơn**: số tiền thay đổi, phải bấm "Trả" mới thành giao dịch [H13][A13].
  - Cả hai **bắt đầu từ kỳ sau** (tạo hôm nay thì lần đầu là tháng sau), **không đồng bộ giữa các máy**, không dùng được cho ví tín dụng [H12][H13].
  - Cả hai hiện ở tab "Tương lai" dưới dạng dòng ảo [H12].

### 1.3 Ngân sách
- **Định nghĩa:** hạn mức chi cho **một danh mục, nhiều danh mục hoặc Tất cả** [H17][T1]. Chỉ chọn được danh mục Chi và Nợ/Cho vay [H17].
- **Phạm vi và kỳ:**
  - Áp cho **một ví hoặc Tổng** (chỉ các ví đang dùng và tính vào tổng) [H17].
  - Kỳ là tuần, tháng, quý, năm hoặc tuỳ chọn.
  - **Lặp lại** được trừ kỳ tuỳ chọn; ngân sách lặp được tạo mới vào ngày đầu kỳ sau [H17][H18].
  - Không cho trùng (cùng danh mục × kỳ × ví) [H17].
- **Không cộng dồn:** hết kỳ là xong, không mang phần dư hay phần vượt sang kỳ sau. Điều này suy ra từ tài liệu, không bài nào nói thẳng [H17][H18].
- **Thanh tiến độ:** xám khi chưa có giao dịch, xanh khi dưới 75%, cam khi từ 75%, đỏ khi vượt. Có thông báo khi chạm 75% (bản cũ báo ở 50/80/100%) [H16][A5]. Vượt ngân sách thì chỉ báo, không chặn gì.
- **Các con số trong chi tiết ngân sách** [H16][H19][A16]:
  - Đã chi, Còn lại, Vượt.
  - **Nên chi mỗi ngày** ≈ còn lại ÷ số ngày còn lại.
  - **Thực chi mỗi ngày** = trung bình đã chi mỗi ngày.
  - **Dự kiến chi cả kỳ**: hồi quy tuyến tính trên chi tiêu cộng dồn.
  - Ví dụ: ngân sách 150$, đã chi 67$, còn 14 ngày → thực chi 5$/ngày, nên chi 6$/ngày, dự kiến 134$ [A15].
- **Tổng các ngân sách:** cha và con cùng có ngân sách thì chỉ tính cha. Có cả ngân sách "Tất cả" lẫn ngân sách danh mục thì app tự sinh **"Ngân sách danh mục khác"** cho phần chi ngoài các danh mục đã đặt. Ngân sách "Tất cả" nhỏ hơn tổng các ngân sách con thì hiện cảnh báo [H16].
- **Ngân sách đã kết thúc:** chỉ xoá được, không sửa [H16].
- **Lịch sử thay đổi:** trước v8, ngân sách chỉ theo từng ví nên không gộp được tiền mặt với thẻ. Đây là lời phàn nàn lâu năm [T2]. Lên v8 thì mất toàn bộ ngân sách cũ [A6].

### 1.4 Sổ giao dịch
- **Chọn ví:** một ví hoặc Tổng [H43].
- **Khoảng thời gian:** Ngày, Tuần, Tháng, Quý, Năm, Tất cả, Tuỳ chọn. Mỗi kiểu có tới 20 tab vuốt ngang. Ở chế độ Tháng chỉ lùi được khoảng 18 tháng [H21][H23]. Có thêm tab **Tương lai** cho các dòng định kỳ và hoá đơn [H12].
- **Dòng tổng ở đầu sổ** (user chọn một trong hai kiểu) [H21]:
  - **Số dư đầu kỳ / cuối kỳ.**
  - **Tiền vào / Tiền ra.** Hai số này *cộng cả* các giao dịch không tính vào báo cáo (chuyển ví, nợ, tiết kiệm), nên **không khớp với "Thu nhập ròng" trong báo cáo** [H26].
- **Cách xem:** **theo giao dịch** (mới nhất trước, nhóm theo ngày) hoặc **theo danh mục** (mỗi danh mục một nhóm) [H21].
- **Tìm kiếm** [H22]:
  - Tìm nhanh theo danh mục, ghi chú, tag.
  - Tìm nâng cao lọc theo ví, **số tiền**, danh mục, ngày.
- **Lịch:** tài liệu chính thức không có dạng xem lịch (**chưa kiểm chứng**, có lẽ không có).

### 1.5 Nợ và cho vay
- **Bốn danh mục:**
  - **Đi vay**: tiền vào, số dư tăng.
  - **Cho vay**: tiền ra, số dư giảm.
  - **Trả nợ**: tiền ra.
  - **Thu nợ**: tiền vào [H27].
- **Theo người:** gắn người cho vay hoặc người vay, sổ nợ nhóm theo người. Giao diện tiếng Việt chia hai cột "Cần trả / Cần thu" [H27][T4].
- **Trả hoặc thu một phần:** bấm trả/thu trên khoản nợ, sửa số tiền, phần còn lại tự cập nhật [H27].
- **Trả từ ví khác** (hướng dẫn cũ): app tự tạo chuyển ví + trả nợ [A8].
- **Mua trả sau:** ghi một khoản chi **và** một khoản nợ cùng số tiền [A7].
- **Trong báo cáo:** Nợ và Cho vay có dòng riêng, không tính là thu chi [H25].
- **User phàn nàn:** "ghi nợ mà không muốn trừ tiền thật" [T3].

### 1.6 Báo cáo
- **Các con số chính:** số dư đầu và cuối kỳ, **thu nhập ròng = thu − chi của các giao dịch có tính báo cáo** [H25][H26].
- **Biểu đồ:**
  - Hai biểu đồ tròn thu và chi. Có nút gộp danh mục con vào danh mục cha [H26].
  - Chi trung bình mỗi ngày.
  - So sánh với **trung bình 3 tháng trước** [H25].
- **Mục riêng:** Nợ, Cho vay, và "Khác" (các giao dịch không tính báo cáo) [H25].
- **Xu hướng** theo tháng, chọn được quý, năm hoặc tuỳ chọn [H25].
- **Trang chủ:** "Báo cáo tháng này" so chi tiêu cộng dồn với cùng khoảng của 3 tháng trước [H47].
- **Công tắc toàn cục "Không tính báo cáo"** (bản cũ): tắt đi thì mọi khoản ra là chi và mọi khoản vào là thu [A2][H26].

### 1.7 Tiết kiệm, đa tiền tệ, onboarding, AI, gói trả phí
- **Mục tiêu:** dùng ví mục tiêu và nạp tiền bằng chuyển ví [H28]. Bản cũ có "kế hoạch tiết kiệm" riêng: nạp là tiền ra, rút là tiền vào, không tính vào số dư [A11].
- **Onboarding:**
  - Hướng dẫn cũ: số dư bắt đầu từ 0, rồi điều chỉnh số dư hoặc nhập một khoản thu [A12].
  - Bản hiện tại (theo một bài phân tích màn hình của bên thứ ba): vài màn giới thiệu → nhập khoản chi đầu tiên → paywall khi thêm ví thứ hai → **dùng thử Premium 14 ngày** sau khi tạo ngân sách đầu tiên [T5][H31].
- **AI** (bản thường được 10 lượt, Premium không giới hạn) [H33]–[H36]:
  - Chat nhập nhiều giao dịch một câu, nhưng **chuyển ví phải gửi riêng**.
  - Quét tới 10 hoá đơn một lần.
  - Siri.
  - **Ghi từ thông báo ngân hàng** qua Shortcuts (8.93, tháng 11/2026) [H35][T1].
- **Gói trả phí:**
  - Bản miễn phí: 1 ví, có quảng cáo, tối đa 2 ngân sách, 1 định kỳ, 1 hoá đơn, 1 sự kiện [H30].
  - Premium trọn đời 599.000 ₫ [T2]. Ví liên kết ngân hàng và Money Insider là gói thu phí riêng [H29][H41][H42].

### 1.8 User khen và chê gì
- **Chê** [T1][T2][T3]:
  - Ngân sách khó dùng.
  - Chuyển ví từng bị tính là thu/chi.
  - Cùng một danh mục ở hai ví không gộp được.
  - Định kỳ "chậm một tháng".
  - Đi vay làm đổi số dư.
  - Định kỳ và tỷ giá không đồng bộ giữa các máy.
  - Nhiều gói trả thêm ngoài Premium.
  - Muốn "reset" số dư mỗi tháng.
- **Khen:** nhập nhanh, biểu đồ thu nhập ròng, **dự báo chi tiêu** của ngân sách, đa tiền tệ, ví chia sẻ cho vợ chồng, Premium trọn đời đáng tiền [T1][T3][T9].

---

## 2. So sánh với Moonee (code trên `main`)

Ký hiệu: ✅ Moonee làm tốt / ngang ML · ⚠️ có nhưng gây rối · ❌ thiếu.

### 2.1 Ví

| Chủ đề | Money Lover | Moonee hôm nay | Đánh giá |
|---|---|---|---|
| Loại ví | thường, liên kết, tín dụng, mục tiêu, chia sẻ | tiền mặt, ngân hàng, ví điện tử, tín dụng, tiết kiệm, đầu tư (`WalletType`) | ✅ đủ cho MVP; không làm liên kết API (spec §0) |
| Tính vào tổng / ngân sách | "Tính vào tổng": ảnh hưởng cả sổ, báo cáo, ngân sách | `Wallet.inBudget`: chỉ ảnh hưởng lọ và Chưa chia; Tổng quan vẫn cộng mọi ví (`walletTotal`) | ✅ rõ nghĩa hơn ML ("tiền để tiêu" và "tiền để dành") |
| Chuyển ví | 2–3 giao dịch + cờ loại khỏi báo cáo | 1 giao dịch `transfer`, không bao giờ là thu/chi (`Ledger.walletDeltas`) | ✅ **tốt hơn ML**; nên có thêm **phí chuyển** (P2) |
| Trả thẻ tín dụng | không có luồng riêng (**chưa kiểm chứng**) | "Trả thẻ" = chuyển ví, có ghi chú giải thích (`PayCardSheet`) | ✅ |
| Điều chỉnh số dư | tạo giao dịch chênh lệch [H5] | sửa `initialBalance`, tức **viết lại toàn bộ lịch sử** (`WalletForm.save`) | ❌ → P1 |
| Lưu trữ ví | có | không (chỉ xoá; xoá thì cascade mọi giao dịch của ví) | ❌ P2 |
| Đa tiền tệ | đổi tỷ giá lúc nhập | cộng thẳng không quy đổi (CLAUDE.md, known gap) | ❌ P2 |

### 2.2 Giao dịch và danh mục

| Chủ đề | Money Lover | Moonee hôm nay | Đánh giá |
|---|---|---|---|
| Nhập | form + chat AI (10 lượt miễn phí) + quét hoá đơn + thông báo ngân hàng | chat (text/giọng/ảnh, model local hoặc BYOK) là kênh chính; form chỉ để sửa | ✅ **Moonee mạnh hơn** ở chat và chạy offline; ❌ chưa ghi được từ thông báo ngân hàng (P2) |
| Danh mục | cha–con, 3 nhóm, gộp, bật/tắt theo ví | phẳng, chỉ chi/thu (`Category.kindRaw`); nợ là *loại giao dịch* chứ không phải danh mục | ✅ phẳng đủ cho người phổ thông; danh mục con là P2 |
| Danh mục "Khác" | "Chưa phân loại" vẫn tính vào báo cáo và ngân sách Tất cả | `category.other` **không thuộc lọ nào**. Đây là danh mục dự phòng khi parser không đoán được (`ChatBook.swift:220`) và danh mục mặc định của hoá đơn tạo ở onboarding (`OnboardingChat.swift:309`) | ⚠️ **lỗi logic lớn**, xem 3.1 |
| Không tính vào báo cáo | cờ trên từng giao dịch | không có | ❌ P1 (dùng ít, nhưng cần cho chi hộ / công tác phí) |
| Sự kiện / chuyến đi | có, kèm Chế độ du lịch | không | P2 |
| Định kỳ | tự ghi, nhưng bắt đầu kỳ sau | `Recurring` chỉ nhắc + nút "Đã trả" / "Đã nhận"; tự ghi chỉ có ở Tự động, và chỉ cho lương (`Autopilot`) | ⚠️ → P1 tự ghi cho khoản cố định; **giữ** quy tắc "ngày đầu tiên là ngày user nói" |
| Sửa giao dịch | đổi được mọi trường | `TxnEditForm`: không đổi được loại; đổi danh mục thì lọ đổi theo và Moonee học quy tắc merchant | ✅ |

### 2.3 Ngân sách: phần owner thấy "chưa đúng"

| Chủ đề | Money Lover | Moonee hôm nay | Đánh giá |
|---|---|---|---|
| Đơn vị ngân sách | hạn mức theo danh mục × ví × kỳ | lọ (phong bì tiền thật), chi trừ qua danh mục → lọ | ✅ giữ lọ; ❌ **thiếu hạn mức danh mục trong lọ** (P1) |
| Cộng dồn | không | có (`JarMonth.start`) | ✅ Moonee tốt hơn: đúng thứ user ML đang xin [H44] |
| Tiền vào chia thế nào | ngân sách không dính tới thu nhập | **ba luật**: thu nhập qua chat/form chia ngay theo % (`Txn.allocate`); lương bấm "Đã nhận" chia theo kế hoạch của Moonee (`BudgetActions.receive`); số dư có sẵn nằm ở Chưa chia vào lọ | ⚠️ **P0**: user không đoán được tiền đi đâu |
| Chi khi lọ hết tiền | thanh đỏ, chỉ báo | lọ âm, "Còn lại" đỏ, dù **Chưa chia vào lọ vẫn còn 20tr** (ảnh `docs/screenshots/s12b/5-plan-a-d.png`: "Còn lại −113.000 ₫ · Tổng ngân sách 0 ₫") | ⚠️ **P0**: con số đúng toán nhưng sai cảm giác |
| Chi không thuộc lọ | (không có khái niệm) | trừ ví nên Chưa chia tụt mà không báo gì; không nằm trong "Đã chi" của tab Ngân sách, nhưng có trong "Chi" của Tổng quan | ⚠️ **P0**: hai con số "đã chi" lệch nhau |
| Mua tài sản / gửi tiết kiệm | chuyển sang ví mục tiêu | chuyển tiền có `jar`, trừ lọ nhưng vào phần "added" (âm), không vào "spent" (`Ledger.jarMonth`) | ⚠️ đúng nhưng khó hiểu: "Tổng ngân sách" của lọ tụt xuống |
| "Nên chi mỗi ngày", dự báo | có, kèm hồi quy [A16] | chỉ có trong thẻ cố vấn khi tiêu nhanh (`pace`) | ❌ P1, cỡ S |
| Cảnh báo | 75% (cũ: 50/80/100) | 80% / 100% theo mức nhắc nhở | ✅ |
| Bố cục tab | tab Ngân sách chỉ có ngân sách | **một List dài**: Cố vấn → Tháng này (chọn tháng, tóm tắt, thu nhập, Chưa chia + menu chia, dòng lương, lời khen) → Lọ → Ví → Hoá đơn (+ Sổ nợ của s19) (`BudgetView`) | ⚠️ **P0**: quá nhiều khái niệm trên một màn |
| Cố vấn | không có (Money Insider chỉ là biểu đồ) | `BudgetAdvisor` 9 loại gợi ý, 3 mức, quỹ khẩn cấp, số tròn | ✅ **khác biệt lớn nhất của Moonee**, nhưng câu chữ đang dài (ảnh s12b/5 có 2 đoạn); nên rút gọn |
| Chọn tháng | tab vuốt, ~18 tháng | menu 12 tháng trước, không xem được tháng sau | ⚠️ |

### 2.4 Sổ giao dịch

| Chủ đề | Money Lover | Moonee hôm nay (`TransactionLedgerView`, `TxnFilter`) | Đánh giá |
|---|---|---|---|
| Kỳ mặc định | tháng này, vuốt sang tháng khác | **Toàn bộ thời gian**; kỳ khác chọn trong menu lọc (tuần / tháng / tháng trước / năm) | ❌ P0 |
| Dòng tổng | đầu/cuối kỳ hoặc vào/ra | không có | ❌ P0 (và đừng lặp lỗi lệch số của ML) |
| Nhóm | theo ngày hoặc theo danh mục | chỉ theo ngày, đầu mục ngày không có tổng | ❌ P0 |
| Theo ví | chọn ví, thấy số dư của ví | lọc theo ví, không có số dư | ❌ P0 |
| Tương lai | tab Tương lai (dòng ảo) | không; hoá đơn 7 ngày tới chỉ có ở Tổng quan | ❌ P0/P1 |
| Tìm / lọc | tìm nhanh + nâng cao (theo số tiền) | tìm ghi chú, danh mục, ví, người, chữ gốc; lọc ví, lọ, danh mục, kỳ | ✅ phần lớn; ❌ thiếu lọc theo loại và số tiền |
| Lịch | không có | s20 làm lịch chi tiêu ở Tổng quan | ✅ (s20, không làm lại) |
| Nhiều thao tác cùng lúc | xoá nhiều, nhân bản | vuốt từng dòng để sửa / xoá | P2 |

### 2.5 Nợ, báo cáo, mục tiêu, onboarding

| Chủ đề | Money Lover | Moonee hôm nay | Đánh giá |
|---|---|---|---|
| Nợ | 4 danh mục, nhóm theo người, trả một phần, nhắc | 3 loại giao dịch lend/borrow/repay + `Debt`; s19 đang làm sổ nợ đầy đủ (Cần thu / Cần trả, trả một phần, hạn, nhắc, chat hỏi hạn trả) | ✅ (s19). Moonee đúng hơn: nợ không trừ lọ, không là thu/chi |
| Mua trả sau | chi + nợ | quẹt thẻ = chi trên ví tín dụng | ✅ |
| Báo cáo | đầu/cuối kỳ, thu nhập ròng, tròn theo danh mục, xu hướng, trung bình 3 tháng | `MonthReport`: so với tháng trước, theo lọ/danh mục, top 5, xu hướng 6 tháng, nhận xét của Moonee | ✅ ngang; P2: so với trung bình 3 tháng, báo cáo tuần/năm |
| Mục tiêu | ví mục tiêu | model `Goal` **có nhưng không có màn nào** | ❌ P2 (spec để bản 2) |
| Onboarding | gần như không thiết lập gì, đẩy dùng thử Premium | chat: thu nhập, ngày lương, ví, hoá đơn, % lọ, mức hỗ trợ | ✅ Moonee tốt hơn; nhưng hoá đơn tạo ở onboarding mặc định là "Khác", không thuộc lọ nào (3.1) |
| Kiếm tiền | miễn phí + Premium + các gói thêm | mua đứt một lần | ✅ |

---

## 3. Moonee đang rối ở đâu (chi tiết)

### 3.1 Ngân sách
1. **Ba cửa cho tiền vào, mỗi cửa một luật.**
   - "nhận thưởng 5tr" trong chat: `Txn.allocate` chia ngay theo %.
   - Lương bấm "Đã nhận": `BudgetActions.receive` chia theo kế hoạch a–d (Thiết yếu đủ tới kỳ lương, bù lọ âm, quỹ khẩn cấp, còn lại theo %), ở mức Gợi ý và Tự động.
   - Số dư ban đầu, ví mới, bán tài sản, rút tiết kiệm: vào Chưa chia, user chia một lần.

   Cùng là "có thêm tiền" mà kết quả khác nhau. User nhắn "nhận lương 15tr" trong chat (chia theo %) sẽ thấy khác với bấm "Đã nhận" (chia theo kế hoạch).
2. **Chi tiêu không thuộc lọ thì lặng lẽ ăn vào Chưa chia.**
   - `category.other` không có lọ. Đây lại là danh mục dự phòng của parser cho mọi khoản chi không đoán được (`ChatBook.swift:220`), và danh mục mặc định của hoá đơn ở onboarding (`OnboardingChat.swift:309`).
   - Hệ quả 1: Chưa chia vào lọ giảm mà không ai giải thích. Khi xuống âm thì hiện "Nhiều hơn số ví đang có".
   - Hệ quả 2: "Đã chi" ở tab Ngân sách (chỉ đếm chi từ lọ, `jarMonth`) khác "Chi" ở Tổng quan (đếm mọi khoản chi, `DashboardStats`).
3. **Chi trước khi chia thì thấy âm, dù vẫn có tiền.** Sau onboarding, user chưa bấm chia, quẹt 113k: tab hiện "Còn lại −113.000 ₫ / Tổng ngân sách 0 ₫ / 100%" bằng chữ đỏ ngay dưới dòng "20.000.000 ₫ chưa vào lọ nào". Đúng nguyên tắc phong bì, nhưng màn hình làm user tưởng app sai.
4. **Quá nhiều khái niệm trên một màn.**
   - Chưa chia vào lọ, Tổng ngân sách, Còn lại, Đã chi, Thu nhập, dòng lương, kế hoạch a–d.
   - Thêm danh sách ví (Tổng trong ví, Trong ngân sách, Nợ thẻ) và hoá đơn, sắp tới là sổ nợ.
   - Trong khi đó ML chỉ có một câu hỏi: "danh mục này còn bao nhiêu?".
5. **"Tổng ngân sách" của một lọ có thể giảm giữa tháng** khi mua tài sản bằng tiền lọ (chuyển tiền có `jar` được tính là "added" âm). User sẽ hỏi "sao ngân sách tự giảm?".
6. **Không có hạn mức theo danh mục.** Lọ Thiết yếu 55% gom chung ăn uống, nhà, đi lại, sức khoẻ. User không đặt được "ăn uống 3tr" như thói quen bên ML.

### 3.2 Sổ giao dịch
1. Mở sổ là thấy toàn bộ lịch sử, không biết tháng này tiêu bao nhiêu.
2. Không có dòng tổng, không nhóm theo danh mục, không có số dư theo ví, không có "Sắp tới".
3. Dòng chuyển ví và chuyển lọ hiện số tiền không dấu (`flow == 0`). Đúng, nhưng không nói rõ là "không tính vào thu chi".
4. Sửa số dư ví thì viết lại lịch sử, không để lại dấu vết trong sổ.

---

## 4. Đề xuất

Thứ tự ưu tiên: **P0** làm ngay, vì đây là thứ owner thấy sai. **P1** lấy cái hay của ML. **P2** để sau.
Công sức: **S** ≤ 1 ngày · **M** 2–3 ngày · **L** ≥ 4 ngày (một session).
Mọi thay đổi model **chỉ thêm, không đổi tên hay xoá** (CloudKit). **Không thêm giá trị mới cho `TxKind`**: bản cũ ở máy khác đọc giá trị lạ thành `.expense` (`TxKind(rawValue:) ?? .expense`), làm sai số dư khi đồng bộ.

### P0-1 · Một luật duy nhất cho tiền vào (M)
**Đề xuất (owner cần chốt, vì đổi quyết định 06/11 "chia ngay theo %"):** *mọi* tiền vào (thu nhập từ chat, form, lương, số dư có sẵn) đều theo **một luật, phụ thuộc mức hỗ trợ**:

| Mức | Khi có tiền vào |
|---|---|
| **Tự động** | Moonee áp kế hoạch a–d ngay. Thẻ trong chat / Ngân sách ghi "Moonee đã chia…" kèm **Hoàn tác** và **Sửa** |
| **Gợi ý** (mặc định) | Tiền nằm ở Chưa chia. Ngay trên thẻ giao dịch trong chat có nút **Chia theo kế hoạch** (một chạm), **Theo %**, **Để sau**. Thẻ Moonee gợi ý ở tab Ngân sách cũng hiện cùng lựa chọn |
| **Tự làm** | Chia theo % ngay (giữ hành vi cũ cho người không muốn gợi ý). Muốn chia khác thì sửa từng khoản |

- **Luồng:**
  1. User nhắn "nhận lương 15tr" (hoặc bấm "Đã nhận" ở dòng lương).
  2. Moonee lưu khoản thu, rồi gọi **một** hàm `BudgetActions.receive(income:)` (gộp `Txn.allocate` của thu nhập, `receive(recurring)` và `splitUnallocated`).
  3. Hàm này xử lý theo mức hỗ trợ như bảng trên.
  4. Khoản thu từ chat cùng danh mục với lương sẽ khớp vào dòng lương như hiện tại (`isReceived`).
- **Model:** không đổi. `IncomeSplit` vẫn là cách lưu. Thu nhập không có split = đang ở Chưa chia (đúng như `Ledger` đang hiểu).
- **Màn hình:**
  - Thẻ giao dịch trong chat (`ChatBook`, `ChatView`).
  - `JarsSection` (dòng Chưa chia).
  - `AdvisorCard`.
  - `TxnEditForm`: thêm mục "Chia vào lọ" khi sửa một khoản thu.
- **Spec:** sửa §4.1 ("Mỗi khoản thu mới được chia ngay…") và §4.3.

### P0-2 · Không còn chi tiêu "mồ côi" (S)
- **Mọi danh mục chi đều phải thuộc một lọ.**
  - Seed: `category.other` → Thiết yếu.
  - Máy đã cài: một lần di chuyển dữ liệu lúc mở app gán lọ cho danh mục chi đang không có lọ. Chỉ là dữ liệu, không đổi schema.
  - Giao dịch cũ giữ nguyên lọ đã ghim (đúng nguyên tắc `allocate`).
- **Chọn lọ khi tạo / sửa danh mục chi:** bắt buộc chọn (`JarMappingView`, form danh mục). Tuỳ chọn "Không thuộc lọ" chuyển xuống phần Nâng cao, kèm giải thích "trừ vào Chưa chia vào lọ".
- **Hoá đơn tạo ở onboarding:** đoán danh mục theo tên (điện, nước, nhà…) bằng `Lexicon`, không gán thẳng "Khác".
- **Kết quả cần đạt:** "Đã chi" ở Ngân sách và "Chi" ở Tổng quan bằng nhau. Test: tổng chi từ các lọ = tổng chi trong tháng.

### P0-3 · Tab Ngân sách gọn lại, con số dễ hiểu (M)
- **Bố cục mới, từ trên xuống:**
  1. **Đầu trang: "Còn tiêu được tháng này"** (= tổng số dư các lọ). Bên dưới là **"Mỗi ngày còn khoảng X"** (= còn lại ÷ số ngày còn lại, P1-3).
     - Nếu Chưa chia > 0, đầu trang **đổi thành lời kêu gọi**: "Bạn có 20tr chưa chia vào lọ · Chia ngay". Không hiện số âm màu đỏ khi vẫn còn tiền chưa chia.
     - Khi lọ âm mà Chưa chia đủ bù: Gợi ý thì hiện một nút **Bù từ tiền chưa chia**; Tự động thì Moonee tự bù và báo lại.
  2. **Một thẻ Moonee gợi ý**: tiêu đề + **một** dòng, chi tiết a–d gập trong "Vì sao?".
  3. **Lọ**: giữ như cũ, thêm hạn mức danh mục trong chi tiết lọ (P1-1).
  4. **Sắp tới**: gộp dòng lương dự kiến và hoá đơn đến hạn trước cuối tháng thành một danh sách, giữ nút "Đã nhận" và "Đã trả".
  5. **Ví** thu gọn thành một dòng "Ví · 25tr · trong ngân sách 22tr", bấm vào mở `WalletsView`. Sổ nợ của s19 cũng một dòng tương tự.
- **Đổi chữ:**
  - Bỏ "Tổng ngân sách", thay bằng "Có trong tháng" (đầu tháng + thêm vào).
  - Mua tài sản / gửi tiết kiệm hiện thành dòng riêng "Đã để dành" trong chi tiết lọ, không trừ vào "Có trong tháng".
  - Cần thêm trường `setAside` vào `JarMonth`. Đây là struct thuần, không phải model.
- **Chọn tháng:** vuốt ngang hoặc mũi tên ‹ ›, giống thẻ lịch của s20.
- **Model:** không đổi.
- **Màn hình:** `BudgetView`, `JarsSection`, `AdvisorCard`, `WalletsView` (dòng tóm tắt), `BillsSection` (thành "Sắp tới"), `Budget.xcstrings`.
- **Phối hợp với s19:** Sổ nợ thành một dòng, không thành cả một mục.

### P0-4 · Sổ giao dịch v2 (L)
- **Kỳ:**
  - Mở sổ là **tháng này**.
  - Vuốt ngang hoặc ‹ › để đổi tháng. Menu có Tuần / Tháng / Năm / Toàn bộ / Tuỳ chọn (chọn hai ngày).
  - Cuối dãy là **"Sắp tới"**: hoá đơn, lương và khoản định kỳ trong 1 / 3 / 12 tháng tới, dạng dòng mờ. Bấm vào thì mở `RecurringForm`; vuốt thì "Ghi ngay".
- **Thẻ tổng đầu sổ:**
  - **Tiền vào · Tiền ra · Chênh lệch** của kỳ.
  - Ba số này **phải bằng đúng** Thu / Chi / Tiết kiệm ở Tổng quan và trong báo cáo tháng: cùng một hàm tính.
  - Dòng chú thích nhỏ: "Chuyển ví, chuyển lọ và vay/cho vay không tính vào thu chi". Đây là cách tránh lỗi lệch số của ML [H21][H26].
- **Khi lọc theo một ví:** thẻ tổng đổi thành **Số dư đầu kỳ → cuối kỳ** của ví đó (`Ledger` đã có số dư theo thời điểm, chỉ cần tính tới ngày đầu kỳ).
- **Cách xem:**
  - **Theo ngày**: đầu mục mỗi ngày có tổng chi của ngày.
  - **Theo danh mục**: mỗi danh mục một nhóm, có tổng và %, xếp theo số tiền.
  - **Theo lọ**: tuỳ chọn, rẻ vì đã có `jar`.
- **Lọc:**
  - Thêm **loại** (chi / thu / chuyển / nợ) và **khoảng số tiền**.
  - Bộ lọc đang bật hiện thành chip dưới ô tìm, chạm để bỏ.
- **Dòng chuyển ví / chuyển lọ:** chữ phụ "Không tính vào thu chi", có biểu tượng mũi tên hai chiều.
- **Model:** không đổi. Tính toán nằm trong một struct thuần mới (ví dụ `LedgerPeriod` trong `Features/Transactions`): tổng của kỳ, số dư đầu/cuối của ví, nhóm theo danh mục. Có unit test.
- **Màn hình:** `TransactionLedgerView`, `TxnFilter`, `TxnRow`. Tổng quan và báo cáo đổi sang dùng hàm tổng chung (`OverviewStats`, `MonthReport`).
- **Phối hợp với s20:** lịch chi tiêu nằm ở Tổng quan. Sau khi s20 vào `main`, sổ có thể thêm chế độ "Lịch" dùng lại `SpendingCalendar` (P2).

### P1-1 · Hạn mức theo danh mục, nằm trong lọ (M)
- **Ý tưởng:** lấy ý "ngân sách danh mục" của ML, nhưng chỉ là **hạn mức**, không giữ tiền. Lọ vẫn là nơi giữ tiền.
- **Luồng:**
  1. Chi tiết lọ Thiết yếu → "Đặt hạn mức" cho Ăn uống: 3tr/tháng.
  2. Mỗi danh mục có thanh tiến độ riêng, đổi màu ở 80% / 100% như lọ.
  3. Moonee nhắc theo mức nhắc nhở.
  4. Chat: "đặt hạn mức ăn uống 3tr" và "ăn uống tháng này còn bao nhiêu?" (tool `monthBudget` thêm dữ liệu từng danh mục).
- **Cảnh báo:** tổng hạn mức trong một lọ > số có trong tháng của lọ → nhắc nhẹ "hạn mức vượt số tiền lọ có", giống cảnh báo của ML [H16].
- **Model (thêm):** `Category.monthlyLimit: Int?` (nil = không đặt).
- **Màn hình:** `JarDetailView`, form danh mục / `JarMappingView`, `Reminders` (`ReminderPlanner`), `BudgetFacts` (`JarLine.categories`), skill `jar-budgeting`.
- **Không làm:** hạn mức theo tuần / quý / tuỳ chọn, hạn mức theo ví. Kỳ là tháng, giống lọ.

### P1-2 · Điều chỉnh số dư và cờ "Không tính vào báo cáo" (M)
- **Điều chỉnh số dư:**
  - Màn Ví → "Cập nhật số dư": nhập số dư thật.
  - Moonee ghi **một khoản thu** (nếu dư) hoặc **chi** (nếu thiếu) bằng phần chênh. Danh mục là danh mục cố định mới `category.adjustment`, **không vào lọ**, cờ không tính báo cáo bật.
  - Phần dư vào Chưa chia; phần thiếu trừ Chưa chia. Đúng với spec §4.1 "sửa số dư → Chưa chia".
  - Không bao giờ sửa `initialBalance` sau khi ví đã có giao dịch (form chỉ cho sửa khi ví còn trống).
- **Không tính vào báo cáo:**
  - Công tắc trong `TxnEditForm` (phần Nâng cao).
  - Chat: "chi hộ sếp 500k" hoặc "công tác phí" → Moonee hỏi "Khoản này có được hoàn lại không?".
  - Giao dịch có cờ vẫn đổi số dư ví, **không** vào Thu/Chi, báo cáo, lọ hay hạn mức.
  - Báo cáo có dòng "Không tính" để không mất dấu.
  - **Không** làm công tắc toàn cục như ML [A2].
- **Model (thêm):** `Txn.excludedFromReport: Bool = false`; seed danh mục `category.adjustment` (dữ liệu). `Ledger.Entry` thêm cờ, khoản chi có cờ thì `jar = nil`.
- **Màn hình:** `WalletsView` / `WalletForm`, `TxnEditForm`, `Ledger`, `OverviewStats`, `MonthReport`, `LedgerPeriod` (P0-4), `ChatBook`.

### P1-3 · "Mỗi ngày còn tiêu được" và dự báo cuối tháng (S)
- **Ở mỗi lọ và đầu tab Ngân sách:** "còn X/ngày" = số dư ÷ số ngày còn lại (làm tròn xuống bước gọn, dùng hàm làm tròn đang có trong `BudgetAdvisor`).
- **Ở chi tiết lọ:** "Với tốc độ này, cuối tháng chi khoảng Y" = đã chi ÷ số ngày đã qua × số ngày của tháng. Đây là công thức của Money Insider [H42], đủ tốt và dễ giải thích hơn hồi quy [A16].
- **Model:** không đổi. Tính trong `BudgetFacts` / `Ledger`.
- **Màn hình:** `JarsSection`, `JarDetailView`; widget của s22 có thể dùng sau.

### P1-4 · Khoản định kỳ tự ghi (S–M)
- **Luồng:**
  1. Trong form hoá đơn có công tắc **"Tự ghi khi đến ngày"**, mặc định bật cho khoản *không* phải ước tính (Netflix, tiền nhà).
  2. Đến ngày, lần mở app tiếp theo Moonee ghi khoản chi (cùng cơ chế `Autopilot`, gắn `externalID = "auto:…"`).
  3. Moonee báo một thẻ "Đã ghi Netflix 260k", có **Hoàn tác**.
  4. Khoản ước tính (điện, nước) vẫn hỏi số thực như hiện tại.
- **Ngày đầu tiên = ngày user nói**, kể cả hôm nay. Không lặp lỗi "bắt đầu kỳ sau" của ML [H12][T1].
- **Đồng bộ:** `Recurring` đã đồng bộ qua iCloud. Nhớ chống ghi trùng khi hai máy cùng mở: kiểm tra đã có giao dịch `auto:<recurring>:<ngày>` chưa.
- **Model (thêm):** `Recurring.autoPost: Bool = false`.
- **Màn hình:** `RecurringForm` / `BillsSection` (hoặc "Sắp tới" của P0-3), `AdvisorActions` (`Autopilot`), `Reminders`.

### P2 (để sau, ghi lại để không quên)

| Việc | Công sức | Ghi chú / model (chỉ thêm) |
|---|---|---|
| Ghi từ thông báo ngân hàng qua Shortcuts (App Intent "Ghi giao dịch" nhận chữ) | M | ML vừa làm (8.93) [H35]. Ở VN ngân hàng báo mọi giao dịch nên rất hợp. Dùng lại parser của chat. Phối hợp với s22 (widget / App Intents) |
| Phí chuyển ví | S | thêm `Txn.fee: Int?` hoặc một khoản chi kèm theo; **không** tách chuyển ví thành hai giao dịch |
| Danh mục con | L | `Category.parent: Category?` + `children` (quan hệ tuỳ chọn, có inverse). Ảnh hưởng picker, báo cáo (gộp theo cha), hạn mức |
| Sự kiện / chuyến đi | M | `Txn.tag: String?` hoặc model `Event`. Chat: "đi Đà Lạt từ mai" bật chế độ chuyến đi |
| Mục tiêu (model đã có, chưa có màn) | M | thêm `Goal.wallet: Wallet?` (quan hệ tuỳ chọn có inverse) để tiến độ = số dư ví tiết kiệm hoặc lọ, khỏi nhập `saved` bằng tay |
| Lưu trữ ví | S | `Wallet.archivedAt: Date?`; ẩn khỏi các picker, giữ lịch sử (đừng bắt user xoá ví, vì xoá thì mất hết giao dịch) |
| Đa tiền tệ (tỷ giá) | L | đổi sang tiền mặc định khi cộng; tỷ giá Vietcombank đã có ở `marketPrice` |
| Báo cáo: so với trung bình 3 tháng, báo cáo tuần/năm | S–M | `MonthReport` |
| Chế độ Lịch trong sổ | S | dùng lại `SpendingCalendar` của s20 |
| Xoá / sửa nhiều, nhân bản giao dịch | S | `TransactionLedgerView` |

### 4.1 Moonee nên giữ (tốt hơn ML)
- **Chat là kênh nhập chính**: nhiều giao dịch một câu, chuyển ví cũng nói được, chạy offline bằng model local, không giới hạn lượt. ML giới hạn 10 lượt và bắt chuyển ví gửi riêng [H33].
- **Lọ có tiền thật và cộng dồn.** Đúng thứ user ML đang xin [H44][T3].
- **Chuyển ví là một giao dịch**, không bao giờ là thu/chi. Trả thẻ là chuyển ví. Nợ không trừ lọ.
- **Cố vấn** với 3 mức hỗ trợ: ML không có gì tương đương.
- **"Tính vào ngân sách"** rõ nghĩa hơn "tính vào tổng" của ML.
- **Mua đứt, không paywall tính năng.**
- **Dữ liệu đồng bộ trọn vẹn qua iCloud.** ML để mất định kỳ khi đăng xuất [H12].

### 4.2 Nên bỏ hoặc làm gọn
- **Ba luật chia tiền** gộp thành một (P0-1).
- **"Tổng ngân sách"** đổi thành "Còn tiêu được" và "Có trong tháng" (P0-3).
- **Thẻ cố vấn:** một dòng, chi tiết gập lại (P0-3).
- **Ví và hoá đơn** không chiếm cả mục trong tab Ngân sách (P0-3).
- **Không học từ ML:** chuyển ví hai giao dịch; công tắc toàn cục "Không tính báo cáo"; ngân sách theo từng ví; "về 0 mỗi tháng"; định kỳ bắt đầu kỳ sau.

---

## 5. Thay đổi model gom lại (đều chỉ thêm)

| Trường mới | Mặc định | Dùng cho |
|---|---|---|
| `Category.monthlyLimit: Int?` | nil | P1-1 |
| `Txn.excludedFromReport: Bool` | false | P1-2 |
| `Recurring.autoPost: Bool` | false | P1-4 |
| Danh mục seed `category.adjustment` (dữ liệu) | — | P1-2 |
| Gán lọ cho `category.other` (dữ liệu, chạy một lần) | — | P0-2 |

Không có `TxKind` mới, không đổi tên, không xoá. `CloudKitSchemaTests` vẫn phải xanh. Trước TestFlight nhớ deploy schema mới lên Production (`docs/RELEASE.md` §2).

---

## 6. Chia session để giao

Thứ tự đề xuất: **S24 → S25** (cùng các file Budget, làm lần lượt). **S26** chạy song song với S24. **S27, S28, S29** sau khi S25 vào `main`. Mỗi session tuân theo CLAUDE.md: test Swift Testing, chuỗi giao diện en + vi (và th/lo nếu bảng đó đã có), dùng một simulator và tắt khi xong.

| Session | Phạm vi | File chính | Xong khi |
|---|---|---|---|
| **S24 · Một luật cho tiền vào + hết chi mồ côi** (P0-1, P0-2) | gộp ba đường chia tiền thành `BudgetActions.receive(income:)` theo mức hỗ trợ; nút chia ngay trên thẻ chat; gán lọ cho mọi danh mục chi (seed + chạy một lần); đoán danh mục cho hoá đơn ở onboarding; sửa spec §4.1/§4.3 | `Core/Models.swift` (Seed, `allocate`), `Features/Budget/AdvisorActions.swift`, `BudgetActions.swift`, `Features/Chat/ChatBook.swift` (+ thẻ trong `ChatView`), `Features/Onboarding/OnboardingBook.swift`/`OnboardingChat.swift`, `Features/Jars/JarMappingView.swift`, `docs/FEATURES.md`, `MooneeTests/BudgetTests.swift` | test: mọi đường tiền vào cho cùng kết quả theo mức hỗ trợ; tổng chi từ lọ = tổng chi tháng |
| **S25 · Tab Ngân sách gọn + mỗi ngày còn tiêu được** (P0-3, P1-3) | đầu trang "Còn tiêu được / mỗi ngày", Chưa chia thành lời kêu gọi, nút bù lọ âm, cố vấn một dòng, "Sắp tới" gộp lương và hoá đơn, ví và nợ thành một dòng, chọn tháng bằng vuốt, `JarMonth.setAside` | `Features/Budget/BudgetView.swift`, `JarsSection.swift`, `AdvisorCard.swift`, `BillsSection.swift`, `Features/Wallets/WalletsView.swift`, `Core/Ledger.swift`, `Core/StoreLedger.swift`, `Budget.xcstrings` | ảnh simulator trước/sau; trạng thái "chưa chia 20tr + đã chi 113k" không còn đỏ |
| **S26 · Sổ giao dịch v2** (P0-4) | mặc định tháng này + vuốt tháng + tuỳ chọn kỳ; thẻ Tiền vào / Tiền ra / Chênh lệch dùng chung với Tổng quan và báo cáo; số dư đầu/cuối khi lọc ví; xem theo ngày / danh mục / lọ; lọc loại và số tiền, chip; tab "Sắp tới" | `Features/Transactions/TransactionLedgerView.swift`, `TxnFilter.swift`, struct mới `LedgerPeriod.swift`, `Features/Overview/OverviewStats.swift`, `Features/Report/MonthReport.swift`, `Transactions.xcstrings`, test mới | Thu/Chi/Chênh lệch giống nhau ở sổ, Tổng quan và báo cáo (test) |
| **S27 · Hạn mức danh mục** (P1-1) | `Category.monthlyLimit`, đặt hạn mức trong chi tiết lọ, thanh tiến độ, nhắc 80/100%, chat đặt/hỏi hạn mức, tool `monthBudget` có dòng theo danh mục | `Core/Models.swift`, `Features/Budget/JarsSection.swift` (`JarDetailView`), `Reminders.swift`, `Core/StoreLedger.swift`, `Features/AI/MooneeTools`, skill `jar-budgeting.*.md`, `QuickParser`/Lexicon | `CloudKitSchemaTests` xanh; test vượt hạn mức |
| **S28 · Điều chỉnh số dư + Không tính vào báo cáo** (P1-2) | "Cập nhật số dư" tạo giao dịch chênh lệch; khoá `initialBalance` khi ví đã có giao dịch; `Txn.excludedFromReport` trong form, chat, Ledger, Tổng quan, báo cáo | `Core/Models.swift`, `Core/Ledger.swift`, `Features/Wallets/WalletsView.swift`, `Features/Transactions/TxnEditForm.swift`, `LedgerPeriod.swift` (sau S26), `OverviewStats.swift`, `MonthReport.swift`, `ChatBook.swift` | test: điều chỉnh → Chưa chia đổi đúng phần chênh, báo cáo không đổi |
| **S29 · Định kỳ tự ghi** (P1-4) | `Recurring.autoPost`, Autopilot ghi khi đến ngày (mọi mức hỗ trợ), thẻ Hoàn tác, chống trùng giữa hai máy | `Core/Models.swift`, `Features/Budget/AdvisorActions.swift` (`Autopilot`), `BillsSection.swift`, `Reminders.swift` | test: ghi đúng một lần vào ngày đến hạn, kể cả hôm nay |

P2 (bảng ở mục 4) chờ owner chọn. Đáng làm sớm nhất là **ghi từ thông báo ngân hàng qua Shortcuts**: làm cùng hoặc ngay sau s22 widgets.

**Câu hỏi cần owner chốt trước S24:** với mức **Gợi ý**, một khoản thu nhắn trong chat (ví dụ "thưởng 5tr") nên (a) nằm ở Chưa chia và hiện nút "Chia theo kế hoạch" ngay trên thẻ (đề xuất), hay (b) vẫn chia ngay theo % như hiện tại, chỉ riêng lương đi theo kế hoạch?

---

## Nguồn

**Trung tâm trợ giúp chính thức (moneylover.zendesk.com)**
- [H1] Definition of wallets — https://moneylover.zendesk.com/hc/en-us/articles/34972671048985-Definition-of-wallets-in-MoneyLover
- [H2] Create, edit, archive and delete wallets — https://moneylover.zendesk.com/hc/en-us/articles/34974522779417-Create-edit-archive-and-delete-wallets
- [H3] Transfer money between wallets — https://moneylover.zendesk.com/hc/en-us/articles/900000358523-Transfer-money-between-wallets
- [H4] How to manage credit cards — https://moneylover.zendesk.com/hc/en-us/articles/37006112179609-How-to-manage-credit-cards-effectively
- [H5] Adjust wallet's balance — https://moneylover.zendesk.com/hc/en-us/articles/35569781199001-Adjust-wallet-s-balance
- [H6] Share a wallet — https://moneylover.zendesk.com/hc/en-us/articles/35187764576793-Share-a-wallet-with-another-user
- [H7] Create, edit and delete transactions — https://moneylover.zendesk.com/hc/en-us/articles/35483252404889-Create-edit-and-delete-transactions
- [H8] Category: definition and usage — https://moneylover.zendesk.com/hc/en-us/articles/34045598720025-Category-Definition-and-Usage
- [H9] Create, edit, delete, merge categories — https://moneylover.zendesk.com/hc/en-us/articles/33742206448793-Create-edit-delete-and-merge-categories
- [H10] Why can't I delete some categories — https://moneylover.zendesk.com/hc/en-us/articles/33815713487769-Why-can-t-I-delete-some-categories
- [H11] Manage categories in wallet edit screen — https://moneylover.zendesk.com/hc/en-us/articles/47183699100825-Manage-categories-in-the-wallet-edit-screen
- [H12] Recurring transactions — https://moneylover.zendesk.com/hc/en-us/articles/36097569751833-Recurring-transactions-Definition-and-Usage
- [H13] Bills — https://moneylover.zendesk.com/hc/en-us/articles/36058137621145-Bills-Definition-and-usage
- [H14] Events and Travel Mode — https://moneylover.zendesk.com/hc/en-us/articles/35969009741337-How-to-use-Events-and-Travel-Mode
- [H15] Duplicate transaction — https://moneylover.zendesk.com/hc/en-us/articles/42475422733081-Duplicate-transaction-feature
- [H16] Budget: definition and usage — https://moneylover.zendesk.com/hc/en-us/articles/34300604750617-Budget-Definition-and-Usage
- [H17] Create, edit, delete budgets — https://moneylover.zendesk.com/hc/en-us/articles/34181313422361-Create-edit-delete-budgets
- [H18] Repeat budget with custom date — https://moneylover.zendesk.com/hc/en-us/articles/34300139605529-Why-can-t-I-set-a-repeat-budget-with-a-custom-date
- [H19] How budget forecast works — https://moneylover.zendesk.com/hc/en-us/articles/900000366946-How-budget-forecast-works
- [H21] View transaction history — https://moneylover.zendesk.com/hc/en-us/articles/35278612706329-View-transaction-history
- [H22] Search for transactions — https://moneylover.zendesk.com/hc/en-us/articles/40818955866649-Search-for-transactions
- [H23] Old data in previous years — https://moneylover.zendesk.com/hc/en-us/articles/36368821853081-Why-can-t-I-see-old-data-in-previous-years
- [H25] Report: definition and usage — https://moneylover.zendesk.com/hc/en-us/articles/34533897137177-Report-Definition-and-Usage
- [H26] Improving your reports — https://moneylover.zendesk.com/hc/en-us/articles/48961508397721-Improving-Your-Reports-What-s-New
- [H27] Debt & Loan — https://moneylover.zendesk.com/hc/en-us/articles/36403994024345-Debt-Loan-definition-and-usage
- [H28] Financial goals / savings — https://moneylover.zendesk.com/hc/en-us/articles/36976160006809-How-to-manage-your-financial-goals-savings-effectively
- [H29] Premium features — https://moneylover.zendesk.com/hc/en-us/articles/35836986998809-Premium-Main-features-and-purchase-instructions
- [H30] Remaining features after trial — https://moneylover.zendesk.com/hc/en-us/articles/34880487222553-Remaining-features-after-free-trial-expiration
- [H31] Activate Premium trial — https://moneylover.zendesk.com/hc/en-us/articles/35846418049945-How-can-I-activate-the-Premium-trial-for-my-MoneyLover-account
- [H33] Add transactions with AI — https://moneylover.zendesk.com/hc/en-us/articles/42320025248409-Add-transactions-faster-and-easier-with-AI-feature
- [H34] Receipts into transactions — https://moneylover.zendesk.com/hc/en-us/articles/58779737086489-Turn-Receipts-into-Transactions-in-Seconds-in-MoneyLover-New-feature
- [H35] Track from payment notifications — https://moneylover.zendesk.com/hc/en-us/articles/63694541655833-How-to-Automatically-Track-Transactions-from-Payment-Notifications
- [H36] Siri AI — https://moneylover.zendesk.com/hc/en-us/articles/62386526509209-How-to-create-transactions-with-Siri-AI
- [H39] Link bank accounts — https://moneylover.zendesk.com/hc/en-us/articles/39118321383577-Link-bank-accounts-with-MoneyLover
- [H41] Linked bank wallet subscription — https://moneylover.zendesk.com/hc/en-us/articles/35707018765209-Linked-Bank-Wallet-Subscription
- [H42] Money Insider — https://moneylover.zendesk.com/hc/en-us/articles/35757921060121-Money-Insider-Definition-usage-and-purchase-instructions
- [H43] New update (v8) — https://moneylover.zendesk.com/hc/en-us/articles/36614437617177-Explore-the-exciting-new-feature-in-MoneyLover-with-new-update
- [H44] How to manage monthly expenses — https://moneylover.zendesk.com/hc/en-us/articles/36882181274137-How-to-manage-monthly-expenses
- [H47] Trending report on Home — https://moneylover.zendesk.com/hc/en-us/articles/35217892493337-Introducing-Trending-Report-in-Home-screen

**Hướng dẫn chính thức cũ (note.moneylover.me, bản lưu Wayback Machine)**
- [A2] Settings menu — https://web.archive.org/web/2021/https://note.moneylover.me/settings-menu/
- [A5] How to create and manage budgets — https://web.archive.org/web/2021/https://note.moneylover.me/how-to-create-and-manage-budgets/
- [A6] Budgets in Money Lover 8.0 — https://web.archive.org/web/2021/https://note.moneylover.me/how-to-use-budgets-in-money-lover-app/
- [A7] Personal debts and loans (purchase on credit) — https://web.archive.org/web/2022/http://note.moneylover.me/how-to-manage-personal-loans-3/
- [A8] Pay debts from a different wallet — https://web.archive.org/web/2022/http://note.moneylover.me/pay-your-debts-from-different-wallet/
- [A11] Saving plans — https://web.archive.org/web/2022/http://note.moneylover.me/how-to-create-and-track-saving-plans/
- [A12] Getting started (iOS) — https://web.archive.org/web/2022/http://note.moneylover.me/how-to-use-money-lover-getting-started-ios/
- [A13] Recurring transactions and bills — https://web.archive.org/web/2022/http://note.moneylover.me/manage-recurring-transaction-bills/
- [A15] Budgets Forecast update — https://web.archive.org/web/2022/http://note.moneylover.me/new-update-budgets-forecast/
- [A16] Budgets Forecast formula — https://web.archive.org/web/2022/http://note.moneylover.me/fyi-budgets-forecast-formula/

**Bên thứ ba**
- [T1] App Store (US) — https://apps.apple.com/us/app/money-lover-expense-manager/id486312413
- [T2] App Store (VN) — https://apps.apple.com/vn/app/money-lover-s%E1%BB%95-thu-chi/id486312413?l=vi
- [T3] JustUseApp review digest — https://justuseapp.com/en/app/486312413/money-lover-expense-manager/reviews
- [T4] Thế Giới Di Động, hướng dẫn dùng — https://www.thegioididong.com/game-app/cach-su-dung-money-lover-chi-tiet-giup-quan-ly-chi-tieu-hieu-1311173
- [T5] ScreensDesign, phân tích onboarding — https://screensdesign.com/showcase/money-lover-expense-manager
- [T9] GummySearch, tổng hợp Reddit — https://gummysearch.com/tools/best-products/expense-tracker/

[H1]: https://moneylover.zendesk.com/hc/en-us/articles/34972671048985-Definition-of-wallets-in-MoneyLover
[H2]: https://moneylover.zendesk.com/hc/en-us/articles/34974522779417-Create-edit-archive-and-delete-wallets
[H3]: https://moneylover.zendesk.com/hc/en-us/articles/900000358523-Transfer-money-between-wallets
[H4]: https://moneylover.zendesk.com/hc/en-us/articles/37006112179609-How-to-manage-credit-cards-effectively
[H5]: https://moneylover.zendesk.com/hc/en-us/articles/35569781199001-Adjust-wallet-s-balance
[H6]: https://moneylover.zendesk.com/hc/en-us/articles/35187764576793-Share-a-wallet-with-another-user
[H7]: https://moneylover.zendesk.com/hc/en-us/articles/35483252404889-Create-edit-and-delete-transactions
[H8]: https://moneylover.zendesk.com/hc/en-us/articles/34045598720025-Category-Definition-and-Usage
[H9]: https://moneylover.zendesk.com/hc/en-us/articles/33742206448793-Create-edit-delete-and-merge-categories
[H10]: https://moneylover.zendesk.com/hc/en-us/articles/33815713487769-Why-can-t-I-delete-some-categories
[H11]: https://moneylover.zendesk.com/hc/en-us/articles/47183699100825-Manage-categories-in-the-wallet-edit-screen
[H12]: https://moneylover.zendesk.com/hc/en-us/articles/36097569751833-Recurring-transactions-Definition-and-Usage
[H13]: https://moneylover.zendesk.com/hc/en-us/articles/36058137621145-Bills-Definition-and-usage
[H14]: https://moneylover.zendesk.com/hc/en-us/articles/35969009741337-How-to-use-Events-and-Travel-Mode
[H15]: https://moneylover.zendesk.com/hc/en-us/articles/42475422733081-Duplicate-transaction-feature
[H16]: https://moneylover.zendesk.com/hc/en-us/articles/34300604750617-Budget-Definition-and-Usage
[H17]: https://moneylover.zendesk.com/hc/en-us/articles/34181313422361-Create-edit-delete-budgets
[H18]: https://moneylover.zendesk.com/hc/en-us/articles/34300139605529-Why-can-t-I-set-a-repeat-budget-with-a-custom-date
[H19]: https://moneylover.zendesk.com/hc/en-us/articles/900000366946-How-budget-forecast-works
[H21]: https://moneylover.zendesk.com/hc/en-us/articles/35278612706329-View-transaction-history
[H22]: https://moneylover.zendesk.com/hc/en-us/articles/40818955866649-Search-for-transactions
[H23]: https://moneylover.zendesk.com/hc/en-us/articles/36368821853081-Why-can-t-I-see-old-data-in-previous-years
[H25]: https://moneylover.zendesk.com/hc/en-us/articles/34533897137177-Report-Definition-and-Usage
[H26]: https://moneylover.zendesk.com/hc/en-us/articles/48961508397721-Improving-Your-Reports-What-s-New
[H27]: https://moneylover.zendesk.com/hc/en-us/articles/36403994024345-Debt-Loan-definition-and-usage
[H28]: https://moneylover.zendesk.com/hc/en-us/articles/36976160006809-How-to-manage-your-financial-goals-savings-effectively
[H29]: https://moneylover.zendesk.com/hc/en-us/articles/35836986998809-Premium-Main-features-and-purchase-instructions
[H30]: https://moneylover.zendesk.com/hc/en-us/articles/34880487222553-Remaining-features-after-free-trial-expiration
[H31]: https://moneylover.zendesk.com/hc/en-us/articles/35846418049945-How-can-I-activate-the-Premium-trial-for-my-MoneyLover-account
[H33]: https://moneylover.zendesk.com/hc/en-us/articles/42320025248409-Add-transactions-faster-and-easier-with-AI-feature
[H34]: https://moneylover.zendesk.com/hc/en-us/articles/58779737086489-Turn-Receipts-into-Transactions-in-Seconds-in-MoneyLover-New-feature
[H35]: https://moneylover.zendesk.com/hc/en-us/articles/63694541655833-How-to-Automatically-Track-Transactions-from-Payment-Notifications
[H36]: https://moneylover.zendesk.com/hc/en-us/articles/62386526509209-How-to-create-transactions-with-Siri-AI
[H39]: https://moneylover.zendesk.com/hc/en-us/articles/39118321383577-Link-bank-accounts-with-MoneyLover
[H41]: https://moneylover.zendesk.com/hc/en-us/articles/35707018765209-Linked-Bank-Wallet-Subscription
[H42]: https://moneylover.zendesk.com/hc/en-us/articles/35757921060121-Money-Insider-Definition-usage-and-purchase-instructions
[H43]: https://moneylover.zendesk.com/hc/en-us/articles/36614437617177-Explore-the-exciting-new-feature-in-MoneyLover-with-new-update
[H44]: https://moneylover.zendesk.com/hc/en-us/articles/36882181274137-How-to-manage-monthly-expenses
[H47]: https://moneylover.zendesk.com/hc/en-us/articles/35217892493337-Introducing-Trending-Report-in-Home-screen
[A2]: https://web.archive.org/web/2021/https://note.moneylover.me/settings-menu/
[A5]: https://web.archive.org/web/2021/https://note.moneylover.me/how-to-create-and-manage-budgets/
[A6]: https://web.archive.org/web/2021/https://note.moneylover.me/how-to-use-budgets-in-money-lover-app/
[A7]: https://web.archive.org/web/2022/http://note.moneylover.me/how-to-manage-personal-loans-3/
[A8]: https://web.archive.org/web/2022/http://note.moneylover.me/pay-your-debts-from-different-wallet/
[A11]: https://web.archive.org/web/2022/http://note.moneylover.me/how-to-create-and-track-saving-plans/
[A12]: https://web.archive.org/web/2022/http://note.moneylover.me/how-to-use-money-lover-getting-started-ios/
[A13]: https://web.archive.org/web/2022/http://note.moneylover.me/manage-recurring-transaction-bills/
[A15]: https://web.archive.org/web/2022/http://note.moneylover.me/new-update-budgets-forecast/
[A16]: https://web.archive.org/web/2022/http://note.moneylover.me/fyi-budgets-forecast-formula/
[T1]: https://apps.apple.com/us/app/money-lover-expense-manager/id486312413
[T2]: https://apps.apple.com/vn/app/money-lover-s%E1%BB%95-thu-chi/id486312413?l=vi
[T3]: https://justuseapp.com/en/app/486312413/money-lover-expense-manager/reviews
[T4]: https://www.thegioididong.com/game-app/cach-su-dung-money-lover-chi-tiet-giup-quan-ly-chi-tieu-hieu-1311173
[T5]: https://screensdesign.com/showcase/money-lover-expense-manager
[T9]: https://gummysearch.com/tools/best-products/expense-tracker/
