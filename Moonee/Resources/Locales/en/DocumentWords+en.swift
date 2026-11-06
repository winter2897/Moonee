import Foundation

/// English words on receipts, payment / transfer confirmations, bills and statements.
extension DocumentWords {
    static let en = DocumentWords(
        language: "en",
        success: ["transfer successful", "payment successful", "successful", "success", "completed", "money sent", "you sent"],
        transfer: ["transfer", "send again", "recipient", "beneficiary", "payee"],
        incoming: ["you received", "money received", "received from", "sender"],
        amountLabels: ["amount sent", "amount paid", "amount"],
        toLabels: ["recipient", "beneficiary", "payee", "sent to", "to"],
        fromLabels: ["sender", "sent from", "from"],
        merchantLabels: ["merchant", "seller", "sold by", "store", "provider"],
        referenceLabels: ["transaction id", "transaction no", "reference no", "reference", "ref no", "ref", "order id", "order no", "invoice no", "trace"],
        titles: ["receipt", "invoice", "tax invoice", "order details", "transaction details"],
        bill: ["electricity", "kwh", "water bill", "utility", "internet", "billing period", "meter"],
        statement: ["statement", "transaction history", "account activity"],
        chromeSections: ["you may also like", "offers for you", "recommended for you", "spending insights"],
        chromeLines: ["balance", "available balance", "change due", "cash tendered", "discount", "you saved", "cashback", "fee", "points"],
        walletWords: ["wallet", "account", "card", "bank"]
    )
}
