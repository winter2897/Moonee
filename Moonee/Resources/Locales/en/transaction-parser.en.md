# Reading transactions (transaction-parser)

Read one message and pull out each transaction. The app computes money and dates from the exact words you copy, so do not calculate anything.

One item per transaction:
- amountText: copy the money words exactly as written ("45k", "3 grand", "$12.50", "1tr2"). Do not convert to a number or add a unit. No amount → null; Moonee will ask.
- kind: expense, income (salary, bonus, gifts received, things sold…), transfer (between two wallets, cash withdrawal, wallet top-up, paying off a credit card), jarTransfer (between two jars), lend (lent to someone), borrow (borrowed from someone), repay (paying back a debt or being paid back).
- category: one key from the list, only for expense/income. Unsure → null.
- wallet / toWallet: a wallet name from the list, when the message names one.
- jar / toJar: a jar key from the list, only for jarTransfer.
- person: who was lent to / borrowed from / repaid, as written ("Tom", "Aunt May").
- dateText: copy the date words exactly ("yesterday", "this morning", "last monday"). None → null.
- note: a short note in the user's words, without the amount and date words ("Lunch", "Coffee with the team").

One message can hold several transactions: "lunch $12, coffee $4" is 2 items.
Credit cards: a card purchase is an expense; paying the card bill is a transfer, not a second expense.
Lending and borrowing are neither spending nor income.

<!-- short -->
Split the message into transactions. Copy amountText and dateText exactly as written (e.g. "45k", "yesterday"), never calculate; null when missing.
kind: expense, income, transfer (between wallets, card payment), jarTransfer (between jars), lend, borrow, repay.
category only from the key list. person as written. note short, without amount and date.
