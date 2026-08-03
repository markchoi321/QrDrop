//
//  ShareSheet.swift
//  QrBinary
//
//  文件导出：保存到「文件」App 与系统分享面板。
//

import UIKit
import LinkPresentation
import UniformTypeIdentifiers

/// 导出入口。
///
/// 真机实测（2.5 MB PDF）：系统分享面板**首次**呈现要 11.6 秒，之后 0.7 秒。
/// 代价在进程之外，且已验证在应用侧无从消除：
///   - 预先创建实例并强制加载其 view：额外花 293 ms，正式呈现仍需 1529 ms（基线 1632 ms），无效
///   - 模拟器上文档选择器反而更慢（冷 2249 ms 对 1632 ms），故不能断言它更快
/// 因此这里同时提供两条路径，各自记录耗时，由实测决定用哪条。
enum FileExport {

    // MARK: - 保存到「文件」

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        /// 自持直到回调，否则 delegate 被提前释放
        var retain: PickerDelegate?

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onFinish(true)
            retain = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
            retain = nil
        }
    }

    /// 保存到「文件」App。走文档选择器，不枚举第三方分享扩展；
    /// 但是否真的更快取决于机器，须以日志实测为准。
    @discardableResult
    static func saveToFiles(url: URL,
                            onPresented: (() -> Void)? = nil,
                            onFinish: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard let top = topViewController() else { return false }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = PickerDelegate(onFinish: onFinish)
        delegate.retain = delegate
        picker.delegate = delegate
        top.present(picker, animated: true, completion: onPresented)
        return true
    }

    // MARK: - 系统分享面板

    /// 提供轻量元数据，避免系统为文档生成 QuickLook 缩略图
    private final class ItemSource: NSObject, UIActivityItemSource {
        let url: URL
        init(url: URL) { self.url = url }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

        func activityViewController(_ controller: UIActivityViewController,
                                    itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }

        func activityViewController(_ controller: UIActivityViewController,
                                    subjectForActivityType type: UIActivity.ActivityType?) -> String {
            url.lastPathComponent
        }

        /// 只给标题，不给图片：系统拿到现成的元数据就不会去生成预览缩略图
        func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
            let meta = LPLinkMetadata()
            meta.title = url.lastPathComponent
            return meta
        }
    }

    /// - Parameter onPresented: 面板真正呈现完成时回调，用于计时
    @discardableResult
    static func share(url: URL, onPresented: (() -> Void)? = nil) -> Bool {
        guard let top = topViewController() else { return false }
        // UIActivityViewController 必须由 UIKit 直接 present。早前包进
        // UIViewControllerRepresentable 再交给 SwiftUI 的 .sheet 承载，
        // 等于把它当子控制器嵌在别的容器里，不是它预期的用法，且 iPad 上会因缺
        // popover 锚点直接抛异常。
        let vc = UIActivityViewController(activityItems: [ItemSource(url: url)],
                                          applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true, completion: onPresented)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
