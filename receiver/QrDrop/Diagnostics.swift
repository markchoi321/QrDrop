//
//  Diagnostics.swift
//  QrDrop
//
//  耗时与内存诊断。定位卡顿时的第一手数据来源。
//

import Foundation

/// 跨线程的取消标志。后台合并线程轮询它，主线程置位。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// 后台合并任务向外上报 0…1 进度的通道。
/// 合并跑在 detached task 上，而会话对象归解码 actor 独占，两边不能直接读写同一个字段。
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Double = 0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    func set(_ v: Double) {
        lock.lock()
        progress = v
        lock.unlock()
    }
}

enum Diagnostics {

    /// 当前进程常驻内存（MB）。接收端会在内存里堆着编码块与源块，
    /// 大文件下这是卡顿的头号嫌疑，值得随日志一起打出来。
    static var residentMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    /// 计时并返回毫秒
    static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    static func memoryTag() -> String {
        String(format: "内存 %.0f MB", residentMB)
    }
}
