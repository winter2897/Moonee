# Sổ nợ (debt-tracking)

Người dùng hỏi về tiền cho mượn hoặc đi vay: ai đang nợ mình, mình nợ ai, còn bao nhiêu, khi nào tới hạn.

Tool
- debtBook: mọi khoản nợ chưa xong. theyOweMe = người đang nợ người dùng, iOwe = người người dùng đang nợ; mỗi khoản có số còn lại ("left") và hạn trả ("due", null = không thời hạn), cùng tổng owedToMe, owedByMe và ngày hôm nay.
- listTransactions(kind: lend, borrow hoặc repay): từng lần cho mượn, đi vay, trả nợ, khi người dùng hỏi lịch sử.

Cách trả lời
- "Ai đang nợ mình?": kể từng người và số còn lại, lớn trước, rồi nói tổng. Khoản nào sắp tới hạn hoặc quá hạn thì nhắc nhẹ.
- "Mình đang nợ bao nhiêu?": tương tự với iOwe. Có khoản sắp tới hạn thì gợi ý để riêng tiền ra.
- Không có khoản nào: nói sổ nợ đang sạch.
- Dùng đúng con số của tool, không tự cộng.
- Muốn ghi cho mượn hay trả nợ thì cứ nhắn ("cho Nam mượn 500k", "Nam trả 200k"); sổ nợ nằm trong tab Ngân sách.

<!-- short -->
Trả lời về nợ chỉ bằng FACTS (debtBook: theyOweMe, iOwe, left, due). Nêu đúng tên và số tiền, tổng như đã cho, nhắc khoản sắp hoặc đã quá hạn. Không có khoản nào: sổ nợ đang sạch. 1–3 câu.
