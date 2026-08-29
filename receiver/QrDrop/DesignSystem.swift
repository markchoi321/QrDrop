//
//  DesignSystem.swift
//  QrDrop
//
//  界面统一的配色、卡片样式与文案格式化。
//  目的只有一个：把协议层的工程量词（编码块 / 源块 / K / T / ε）挡在界面之外，
//  普通用户在主流程里只应看到「文件名 + 百分比 + 大小 + 一句话状态」。
//

import SwiftUI

// MARK: - 视觉常量

enum Theme {
    static let accent = Color(red: 0.16, green: 0.44, blue: 0.98)
    static let success = Color(red: 0.13, green: 0.70, blue: 0.42)
    static let warning = Color(red: 0.95, green: 0.60, blue: 0.10)
    static let danger  = Color(red: 0.90, green: 0.26, blue: 0.24)

    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16

    /// 主按钮渐变，仅用于「扫描」这一个入口，保证全局只有一个视觉重心
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.24, green: 0.52, blue: 1.0), Color(red: 0.10, green: 0.36, blue: 0.92)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - 卡片容器

struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardModifier(padding: padding))
    }

    /// 让卡片放进 List 后仍保持「浮在分组背景上的独立卡片」的样子：
    /// 去掉行内边距、分隔线与行背景，只留卡片自身。滑动删除是 List 行才有的能力，
    /// 所以列表不能用 ScrollView + LazyVStack
    func listRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - 主按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    var tint: LinearGradient = Theme.accentGradient

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 次级按钮：卡片内的「保存」「重试」等
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 文案格式化

enum AppFormat {

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(max(0, count)))
    }

    static func percent(_ value: Double) -> String {
        // 不做四舍五入到 100%：没真正收齐时显示 100% 会让人以为卡住了
        let p = min(0.999, max(0, value)) * 100
        return String(format: "%.0f%%", p.rounded(.down))
    }

    /// 剩余时间。速率为 0 或估算不可信时返回 nil，由调用方决定不显示
    static func eta(remainingBytes: Int, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 32, remainingBytes > 0 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        guard seconds.isFinite, seconds < 24 * 3600 else { return nil }
        if seconds < 60 { return "约 \(Int(seconds.rounded())) 秒" }
        if seconds < 3600 { return "约 \(Int((seconds / 60).rounded())) 分钟" }
        return String(format: "约 %.1f 小时", seconds / 3600)
    }

    /// 按扩展名给一个能一眼认出的图标
    static func icon(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf":                                   return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp":
                                                      return "photo"
        case "zip", "rar", "7z", "tar", "gz":         return "doc.zipper"
        case "mp4", "mov", "avi", "mkv":              return "film"
        case "mp3", "wav", "m4a", "flac", "aac":      return "music.note"
        case "txt", "md", "log", "json", "xml", "yml", "yaml":
                                                      return "doc.text"
        case "doc", "docx", "pages":                  return "doc.text.fill"
        case "xls", "xlsx", "csv", "numbers":         return "tablecells"
        case "ppt", "pptx", "key":                    return "rectangle.on.rectangle"
        case "dmg", "pkg", "ipa", "apk", "exe", "msi":return "shippingbox"
        default:                                      return "doc"
        }
    }
}
