//
//  SessionDisplay.swift
//  QrDrop
//
//  会话快照 -> 面向普通用户的展示语义。
//
//  协议层的主计量单位是「编码块」，但那是喷泉码的实现细节：用户只关心
//  「这个文件收到多少了」。这里把块数换算成字节，把五种内部状态收敛成
//  四个用户能理解的阶段，界面层一律只读本文件给出的属性。
//

import SwiftUI

/// 用户视角的四个阶段。内部的「收齐但未合并」与「正在合并」都归为「处理中」——
/// 合并已改为自动触发，用户不需要知道这中间还有一道手动关卡。
enum SessionPhase {
    case receiving      // 接收中
    case processing     // 收齐了，正在还原文件
    case done           // 文件已就绪
    case failed         // 还原失败，需要重试
}

extension SessionSnapshot {

    var phase: SessionPhase {
        if isFinished { return .done }
        if failureMessage != nil { return .failed }
        if isFinalizing || isComplete { return .processing }
        return .receiving
    }

    /// 文件名。发送端的文件名在头部里，通常收到前几个源块就能解出；
    /// 解出之前不暴露 sessionId，那对用户没有意义
    var friendlyName: String {
        if let name = fileName, !name.isEmpty { return name }
        return "正在识别文件…"
    }

    /// 文件名是否已经解析出来
    var hasFileName: Bool { fileName?.isEmpty == false }

    /// 传输总量估算（字节）。已知原始大小时用它，否则用 K x T 这个流长度上界
    var totalBytesEstimate: Int {
        if let size = originalSize, size > 0 { return Int(size) }
        return K * T
    }

    /// 已接收量估算（字节）。按主进度折算，仅用于展示
    var receivedBytesEstimate: Int {
        if let final = finalSize { return final }
        return Int(Double(totalBytesEstimate) * min(1, blockProgress))
    }

    var remainingBytesEstimate: Int {
        max(0, totalBytesEstimate - receivedBytesEstimate)
    }

    /// 展示用进度：完成后恒为 1，避免估算误差让完成的文件停在 98%
    var displayProgress: Double {
        switch phase {
        case .done:       return 1
        case .processing: return 1
        default:          return min(1, blockProgress)
        }
    }

    var statusText: String {
        switch phase {
        case .receiving:
            return "接收中 · \(AppFormat.bytes(receivedBytesEstimate)) / \(AppFormat.bytes(totalBytesEstimate))"
        case .processing:
            return isFinalizing ? "正在还原文件…" : "已收齐，准备还原…"
        case .done:
            return "已完成 · \(AppFormat.bytes(finalSize ?? totalBytesEstimate))"
        case .failed:
            return "还原失败，可重试"
        }
    }

    var accentColor: Color {
        switch phase {
        case .receiving:  return Theme.accent
        case .processing: return Theme.warning
        case .done:       return Theme.success
        case .failed:     return Theme.danger
        }
    }

    var iconName: String {
        switch phase {
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .processing: return "gearshape.2.fill"
        case .receiving:  return AppFormat.icon(forFileName: fileName ?? "")
        }
    }

    /// 是否该由界面自动触发合并：收齐、未在合并、也没失败过。
    /// 失败过的不自动重试，否则会陷入「失败 -> 立刻重试 -> 再失败」的循环
    var needsAutoFinalize: Bool {
        isComplete && !isFinished && !isFinalizing && failureMessage == nil
    }
}

extension LegacyFileSnapshot {
    var displayProgress: Double {
        totalChunks > 0 ? Double(receivedChunks) / Double(totalChunks) : 0
    }
}
