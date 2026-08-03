//
//  SessionId.swift
//  QrBinary
//
//  L5 会话标识的确定性推导。对应 CONTRACT.md 第 7 节。
//  正常接收时 sessionId 直接读帧头，这里的推导仅用于完成后的自检与测试向量比对。
//

import Foundation

enum SessionId {

    /// sessionId = SHA256( sha256(文件内容) ‖ T(2B) ‖ K(3B) ‖ codec(1B) ) 的前 4 字节，大端
    static func derive(contentSha256: [UInt8], T: Int, K: Int, codec: Codec) -> UInt32 {
        var buf = contentSha256
        ByteOps.appendUInt16(&buf, UInt16(T))
        ByteOps.appendUInt24(&buf, UInt32(K))
        buf.append(codec.rawValue)
        let digest = StreamCodec.sha256(buf)
        return ByteOps.readUInt32(digest, 0)
    }

    /// 8 位小写十六进制，用于进度文件名与 UI 占位
    static func hex(_ sessionId: UInt32) -> String {
        String(format: "%08x", sessionId)
    }
}
