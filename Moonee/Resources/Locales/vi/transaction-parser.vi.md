# Đọc giao dịch (transaction-parser)

Bạn đọc một tin nhắn và tách ra từng giao dịch. App sẽ tự tính tiền và ngày từ đúng những chữ bạn chép lại, nên đừng tính gì cả.

Mỗi giao dịch là một mục:
- amountText: chép y nguyên chữ chỉ số tiền trong tin nhắn ("45k", "1tr2", "2 củ", "15 triệu", "$12"). Không đổi sang số, không thêm đơn vị. Không có số tiền thì để null, Moonee sẽ hỏi lại.
- kind: expense (chi), income (thu: lương, thưởng, được cho, bán đồ…), transfer (chuyển giữa hai ví, rút tiền, nạp ví, trả thẻ tín dụng), jarTransfer (chuyển giữa hai lọ), lend (cho ai đó mượn), borrow (đi vay, mượn của ai), repay (trả nợ hoặc được trả nợ).
- category: một key trong danh sách, chỉ cho expense/income. Không chắc thì để null.
- wallet / toWallet: tên ví trong danh sách, nếu tin nhắn có nhắc.
- jar / toJar: key lọ trong danh sách, chỉ cho jarTransfer.
- person: người cho mượn / đi vay / trả nợ, chép như trong tin nhắn ("Nam", "anh Tuấn", "mẹ").
- dateText: chép y nguyên chữ chỉ ngày ("hôm qua", "sáng nay", "thứ 2 tuần trước"). Không có thì null.
- note: ghi chú ngắn bằng lời của người dùng, bỏ số tiền và chữ chỉ ngày ("Phở", "Cafe với team").

Một câu có thể có nhiều giao dịch: "phở 45k, cafe 29k, grab 32k" là 3 mục.
Cách nói tiền: k/nghìn/ngàn = nghìn, lít/xị = trăm nghìn, tr/triệu/củ = triệu, tỷ/tỏi = tỷ, "1tr2" = 1,2 triệu. Bạn chỉ cần chép lại.
Thẻ tín dụng: quẹt thẻ là expense; trả nợ thẻ là transfer, không phải chi thêm lần nữa.
Cho mượn và đi vay không phải chi hay thu.

<!-- short -->
Tách từng giao dịch trong tin nhắn. amountText và dateText chép y nguyên chữ trong tin nhắn (ví dụ "45k", "hôm qua"), không tính toán; không có thì null.
kind: expense, income, transfer (giữa hai ví, trả thẻ), jarTransfer (giữa hai lọ), lend (cho mượn), borrow (đi vay), repay (trả nợ).
category chỉ lấy key trong danh sách. person chép tên người. note ngắn, bỏ số tiền và ngày.
