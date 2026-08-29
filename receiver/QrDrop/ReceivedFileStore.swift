//
//  ReceivedFileStore.swift
//  QrDrop
//
//  已完成文件的清单。
//
//  合并落盘之后，会话的中间态与进度文件都被删掉了——这是对的，那些数据已经没用。
//  但先前「完成」这件事只活在内存里的 sessions 字典中，App 一退出就没了：文件还躺在
//  received/ 目录里，界面上却再也找不到入口，等同于被删除。
//
//  所以完成的文件另立一份清单落盘，与进度文件的生命周期完全分开。
//  清单只记文件名不记绝对路径：iOS 的沙盒容器路径在重装、迁移后会变，存下来就是过期的。
//

import Foundation

/// 一条已完成记录
struct ReceivedFileRecord: Codable, Sendable, Equatable, Identifiable {
    let sessionId: UInt32
    let fileName: String
    let size: Int
    let receivedAt: Date

    var id: UInt32 { sessionId }

    /// 每次按当前容器路径重新拼，不使用落盘时的绝对路径
    var url: URL { ReceivedFileStore.directory.appendingPathComponent(fileName) }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

enum ReceivedFileStore {

    /// 最终文件的存放目录
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("received", isDirectory: true)
    }

    /// 清单文件。放在 received/ 之外，避免被「清空已接收文件」的目录遍历顺带删掉，
    /// 那样会留下一份删不干净的状态
    private static var manifestURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("received.manifest.json")
    }

    /// 读清单，并丢掉文件已不存在的记录（用户可能在「文件」App 里删掉了它）
    static func load() -> [ReceivedFileRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([ReceivedFileRecord].self, from: data) else {
            return []
        }
        return records.filter(\.exists)
    }

    static func save(_ records: [ReceivedFileRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    static func removeManifest() {
        try? FileManager.default.removeItem(at: manifestURL)
    }
}
