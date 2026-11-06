import Foundation

/// Lao words on receipts, bank / e-wallet slips (BCEL One, LDB, U-Money…), bills and statements.
/// Written as people type them, without spaces; matched anywhere in a row (`DocumentReader`).
extension DocumentWords {
    static let lo = DocumentWords(
        language: "lo",
        success: ["ໂອນເງິນສຳເລັດ", "ຊຳລະເງິນສຳເລັດ", "ທຸລະກຳສຳເລັດ", "ສຳເລັດ"],
        transfer: ["ໂອນເງິນ", "ໂອນອີກຄັ້ງ", "ຜູ້ຮັບ", "ບັນຊີປາຍທາງ"],
        incoming: ["ຮັບເງິນສຳເລັດ", "ໄດ້ຮັບເງິນ", "ເງິນເຂົ້າ", "ຜູ້ໂອນ"],
        amountLabels: ["ຈຳນວນເງິນ", "ຍອດເງິນໂອນ", "ຍອດເງິນ"],
        toLabels: ["ຊື່ຜູ້ຮັບ", "ຜູ້ຮັບ", "ບັນຊີປາຍທາງ", "ໄປຫາ", "ຫາ"],
        fromLabels: ["ຜູ້ໂອນ", "ບັນຊີຕົ້ນທາງ", "ຈາກ"],
        merchantLabels: ["ຊື່ຮ້ານຄ້າ", "ຮ້ານຄ້າ", "ຜູ້ຂາຍ"],
        referenceLabels: ["ເລກທີອ້າງອີງ", "ລະຫັດອ້າງອີງ", "ລະຫັດທຸລະກຳ", "ເລກທີທຸລະກຳ", "ເລກທີໃບບິນ"],
        titles: ["ໃບຮັບເງິນ", "ໃບບິນ", "ໃບເກັບເງິນ", "ລາຍລະອຽດທຸລະກຳ"],
        bill: ["ຄ່າໄຟຟ້າ", "ໄຟຟ້າລາວ", "ຄ່ານ້ຳປະປາ", "ນ້ຳປະປາ", "ອິນເຕີເນັດ", "ຄ່າໂທລະສັບ"],
        statement: ["ລາຍການເຄື່ອນໄຫວບັນຊີ", "ປະຫວັດທຸລະກຳ", "ລາຍການເຄື່ອນໄຫວ"],
        chromeSections: ["ໂປຣໂມຊັ່ນ", "ສິດທິພິເສດ", "ແນະນຳສຳລັບເຈົ້າ"],
        chromeLines: ["ຍອດເງິນຄົງເຫຼືອ", "ຍອດຄົງເຫຼືອ", "ຄ່າທຳນຽມ", "ສ່ວນຫຼຸດ", "ເງິນທອນ", "ຄະແນນ"],
        walletWords: ["ບັນຊີ", "ກະເປົາເງິນ", "ບັດ", "ທະນາຄານ"]
    )
}
