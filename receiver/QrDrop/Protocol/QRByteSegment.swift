//
//  QRByteSegment.swift
//  QrDrop
//
//  从 QR 原始数据码字中取出字节模式段。
//

import Foundation

/// Vision 的 `VNBarcodeObservation.payloadData` 给的不是「二维码里写进去的那串字节」，
/// 而是**纠错后的原始数据码字流**：4 bit 模式指示符 + 8/16 bit 字符计数 + 数据 + 终止符 + 填充。
///
/// 也就是说数据整体错位 20 bit（V10 及以上），且尾部带着 ZXing 的 0xEC/0x11 填充。
/// 直接把 payloadData 当帧字节用，首字节会是 0x40 而不是帧魔数 0x56，帧全部被丢弃。
///
/// 实测（macOS Vision，V15–V40 十档）：payloadData 长度恒为「该版本数据码字数」，
/// 例如 V40-L 为 2956，而字节模式最大容量是 2953，差的 3 字节正是模式与长度字段。
enum QRByteSegment {

    /// 按位解析出字节模式段的原始内容。
    /// - Parameters:
    ///   - codewords: 纠错后的数据码字（`payloadData` 或 `CIQRCodeDescriptor.errorCorrectedPayload`）
    ///   - symbolVersion: QR 版本 1–40，决定字符计数字段是 8 bit 还是 16 bit
    /// - Returns: 段内原始字节；模式非字节模式或长度越界时返回 nil
    static func extract(codewords: [UInt8], symbolVersion: Int) -> [UInt8]? {
        var bitPos = 0
        let totalBits = codewords.count * 8

        func readBits(_ n: Int) -> Int? {
            guard bitPos + n <= totalBits else { return nil }
            var v = 0
            for _ in 0..<n {
                let bit = (Int(codewords[bitPos >> 3]) >> (7 - (bitPos & 7))) & 1
                v = (v << 1) | bit
                bitPos += 1
            }
            return v
        }

        // 只处理字节模式。旧发送端设了 CHARACTER_SET hint 会插入 ECI 段（模式 0111），
        // 那条路径走 payloadStringValue，不在这里处理。
        guard let mode = readBits(4), mode == 0b0100 else { return nil }
        let countBits = symbolVersion <= 9 ? 8 : 16
        guard let count = readBits(countBits), count > 0 else { return nil }
        guard bitPos + count * 8 <= totalBits else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let b = readBits(8) else { return nil }
            out.append(UInt8(b))
        }
        return out
    }
}
