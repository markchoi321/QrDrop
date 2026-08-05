//
//  Decoders.swift
//  QrDrop
//
//  L3 解码器：解方程（增量高斯消元）与剥洋葱（BP 剥离）。
//  对应 CONTRACT.md 第 3.2 / 4.4 节。剥离解码维护倒排索引，避免传播步全表扫描。
//
//  持久化采用增量日志：解码器把「写一次后永不回改」的成果吐进 journal，
//  由 ProgressStore 追加到磁盘。两个解码器的成果侧本来就是追加式的——
//  解方程的基行落进空 pivot 槽后不再修改，剥洋葱的 solved[i] 一旦写入终身不变。
//

import Foundation

/// 进度记录。增量日志与 checkpoint 共用一套记录，checkpoint 就是日志压实后的形态。
enum ProgressRecord {
    /// 已收 blockId，仅用于去重与统计
    case seen(blockId: UInt32)
    /// seen 的压实形态：blockId 近乎连续，位图比逐条 seen 小一个数量级
    case seenMap(base: UInt32, bitCount: Int, bits: [UInt8])
    /// 剥洋葱：已解出的源块。写入后终身不变
    case solved(index: Int, data: [UInt8])
    /// 剥洋葱：度 ≥2 进入 pending 的原始块，载荷未与任何已解块异或。
    /// 它的度与邻居是 blockId 的确定函数，残值是 (原始块, 已解集合) 的纯函数，
    /// 因此这条记录随后无论降度多少次都不必回改
    case rawBlock(blockId: UInt32, payload: [UInt8])
    /// 剥洋葱：pending 残值。只出现在 checkpoint 里，是若干 rawBlock 压实的结果
    case pending(blockId: UInt32, neighbors: [Int], payload: [UInt8])
    /// 解方程：新增的一行消元基。落进空 pivot 槽后不再修改
    case basis(pivot: Int, coeff: BitSet, data: [UInt8])
}

extension ProgressRecord {
    /// 把 blockId 集合压成位图记录，空集合返回 nil
    static func seenMap(of ids: Set<UInt32>) -> ProgressRecord? {
        guard let lo = ids.min(), let hi = ids.max() else { return nil }
        let n = Int(hi - lo) + 1
        var bits = [UInt8](repeating: 0, count: (n + 7) / 8)
        for id in ids {
            let off = Int(id - lo)
            bits[off >> 3] |= UInt8(1) << UInt8(off & 7)
        }
        return .seenMap(base: lo, bitCount: n, bits: bits)
    }
}

protocol BlockDecoder: AnyObject {
    var K: Int { get }
    var T: Int { get }
    /// 进度计数：剥洋葱为已解出源块数，解方程为消元秩
    var solvedCount: Int { get }
    var pendingCount: Int { get }
    var isComplete: Bool { get }

    /// 解码状态是否已释放（完成落盘后不再保留编码块与源块）
    var isReleased: Bool { get }

    /// 返回 false 表示该 blockId 已收过
    func add(blockId: UInt32, payload: ArraySlice<UInt8>) -> Bool

    /// 完成后拼接全部源块，长度 K × T。
    /// - Parameters:
    ///   - progress: 0…1，仅在耗时较长的解方程回代中会多次回调
    ///   - isCancelled: 返回 true 则中止并返回 nil
    func assemble(progress: ((Double) -> Void)?, isCancelled: () -> Bool) -> [UInt8]?

    /// 释放全部块数据。完成并落盘后调用，避免几十 MB 的中间态一直占着内存
    func releaseStorage()

    // MARK: 持久化

    /// 取走自上次调用以来新产生的增量记录，取走即清空
    func takeJournal() -> [ProgressRecord]
    /// 未取走的增量记录条数，供写盘时机判断
    var journalCount: Int { get }
    /// 当前状态压实后的完整记录序列，用于 checkpoint
    func snapshotRecords() -> [ProgressRecord]
    /// checkpoint 的估算字节数，用于决定日志何时该压实
    var snapshotByteEstimate: Int { get }
    /// 重放记录序列，返回被自检丢弃的记录数
    @discardableResult
    func replay(_ records: [ProgressRecord]) -> Int
}

extension BlockDecoder {
    @discardableResult
    func add(blockId: UInt32, payload: [UInt8]) -> Bool {
        add(blockId: blockId, payload: payload[...])
    }

    /// 不关心进度也不需要取消时的简写
    func assemble() -> [UInt8] {
        assemble(progress: nil, isCancelled: { false }) ?? []
    }
}

// MARK: - 解方程方案

final class LinearSolveDecoder: BlockDecoder {

    let K: Int
    let T: Int
    private let composer: LinearSolveComposer
    /// 以 pivot 为下标的消元基
    private var basisCoeff: [BitSet?]
    private var basisData: [[UInt8]?]
    private var rank = 0
    private var seen = Set<UInt32>()
    private var released = false
    private var journal: [ProgressRecord] = []

    init(K: Int, T: Int) {
        self.K = K
        self.T = T
        self.composer = LinearSolveComposer(K: K)
        self.basisCoeff = [BitSet?](repeating: nil, count: K)
        self.basisData = [[UInt8]?](repeating: nil, count: K)
    }

    // 释放后不再持有块数据，但对外仍表现为「已完成、K 个源块齐了」
    var solvedCount: Int { released ? K : rank }
    var pendingCount: Int { released ? 0 : rank }
    var isComplete: Bool { released || rank == K }
    var isReleased: Bool { released }

    func add(blockId: UInt32, payload: ArraySlice<UInt8>) -> Bool {
        guard seen.insert(blockId).inserted else { return false }
        journal.append(.seen(blockId: blockId))
        var c = composer.coefficients(blockId)
        var d = Array(payload)
        while let p = c.highestBit {
            if let bc = basisCoeff[p] {
                c.xor(bc)
                ByteOps.xorInPlace(&d, basisData[p]!)
            } else {
                basisCoeff[p] = c
                basisData[p] = d
                rank += 1
                // 基行一旦落位就再不修改，可直接追加进日志
                journal.append(.basis(pivot: p, coeff: c, data: d))
                break
            }
        }
        return true
    }

    /// 回代：按 pivot 升序把上三角化简为单位阵。代价是 O(K^2) 次块异或——K=2503 时实测
    /// Release 约 90 ms、Debug 达 6–8 秒，因此必须支持进度回调与中途取消。
    func assemble(progress: ((Double) -> Void)?, isCancelled: () -> Bool) -> [UInt8]? {
        var out = [[UInt8]?](repeating: nil, count: K)
        for p in 0..<K {
            // 每 128 个 pivot 检查一次取消并上报进度，摊薄回调开销
            if p & 0x7F == 0 {
                if isCancelled() { return nil }
                progress?(Double(p) / Double(K))
            }
            guard var c = basisCoeff[p], var d = basisData[p] else { continue }
            c.clear(p)
            while let q = c.highestBit {
                if let dq = out[q] { ByteOps.xorInPlace(&d, dq) }
                c.clear(q)
            }
            out[p] = d
        }
        if isCancelled() { return nil }
        progress?(1.0)
        var result = [UInt8]()
        result.reserveCapacity(K * T)
        for p in 0..<K {
            result.append(contentsOf: out[p] ?? [UInt8](repeating: 0, count: T))
        }
        return result
    }

    func releaseStorage() {
        basisCoeff = []
        basisData = []
        seen = []
        journal = []
        released = true
    }

    // MARK: 持久化

    func takeJournal() -> [ProgressRecord] {
        defer { journal.removeAll(keepingCapacity: true) }
        return journal
    }

    var journalCount: Int { journal.count }

    /// 解方程会话没有中间态的源块，全部状态都在消元基里
    func snapshotRecords() -> [ProgressRecord] {
        guard !released else { return [] }
        var out: [ProgressRecord] = []
        out.reserveCapacity(rank + 1)
        for p in 0..<K {
            guard let c = basisCoeff[p], let d = basisData[p] else { continue }
            out.append(.basis(pivot: p, coeff: c, data: d))
        }
        if let map = ProgressRecord.seenMap(of: seen) { out.append(map) }
        return out
    }

    var snapshotByteEstimate: Int {
        released ? 0 : rank * (4 + (K + 7) / 8 + T) + seen.count / 8 + 64
    }

    @discardableResult
    func replay(_ records: [ProgressRecord]) -> Int {
        var dropped = 0
        for case let .basis(pivot, coeff, data) in records {
            guard pivot >= 0, pivot < K, data.count == T, coeff.bitCount == K else {
                dropped += 1; continue
            }
            // pivot 必须是系数向量的最高位，否则文件已损坏
            guard coeff.highestBit == pivot else { dropped += 1; continue }
            if basisCoeff[pivot] == nil { rank += 1 }
            basisCoeff[pivot] = coeff
            basisData[pivot] = data
        }
        replaySeen(records, into: &seen)
        journal.removeAll(keepingCapacity: true)
        return dropped
    }
}

// MARK: - 剥洋葱方案

final class PeelingDecoder: BlockDecoder {

    private struct PendingEntry {
        var blockId: UInt32
        var neighbors: Set<Int>
        var payload: [UInt8]
    }

    let K: Int
    let T: Int
    private let composer: PeelingComposer
    private var solved: [[UInt8]?]
    private var solvedTotal = 0
    private var pending: [PendingEntry?] = []
    private var freeSlots: [Int] = []
    /// 倒排索引：源块索引 -> pending 下标集合
    private var inv: [Set<Int>]
    private var seen = Set<UInt32>()
    private var released = false
    private var journal: [ProgressRecord] = []
    /// 重放期间不再产生日志，否则恢复一次就把整份状态重新写一遍
    private var replaying = false

    init(K: Int, T: Int, soliton: RobustSoliton? = nil) {
        self.K = K
        self.T = T
        self.composer = PeelingComposer(K: K, soliton: soliton)
        self.solved = [[UInt8]?](repeating: nil, count: K)
        self.inv = [Set<Int>](repeating: [], count: K)
    }

    var solvedCount: Int { released ? K : solvedTotal }
    var pendingCount: Int { released ? 0 : pending.count - freeSlots.count }
    var isComplete: Bool { released || solvedTotal == K }
    var isReleased: Bool { released }

    /// 读取已解出的源块，供 StreamHeader 提前解析
    func solvedBlock(_ index: Int) -> [UInt8]? {
        guard !released, index >= 0, index < solved.count else { return nil }
        return solved[index]
    }

    @inline(__always)
    private func note(_ record: ProgressRecord) {
        if !replaying { journal.append(record) }
    }

    func add(blockId: UInt32, payload: ArraySlice<UInt8>) -> Bool {
        guard seen.insert(blockId).inserted else { return false }
        // 原始载荷与消元用的副本共享存储，第一次异或才真正分裂（COW）
        let raw = Array(payload)
        var pay = raw
        var remaining = Set<Int>()
        for i in composer.neighborsOf(blockId) {
            if let s = solved[i] {
                ByteOps.xorInPlace(&pay, s)
            } else {
                remaining.insert(i)
            }
        }
        if remaining.isEmpty {
            note(.seen(blockId: blockId))
            return true
        }
        if remaining.count == 1 {
            // 直接剥出源块，产出的 solved 记录已包含全部信息，原始块不必留
            note(.seen(blockId: blockId))
            propagate(remaining.first!, pay)
        } else {
            note(.rawBlock(blockId: blockId, payload: raw))
            insertPending(PendingEntry(blockId: blockId, neighbors: remaining, payload: pay))
        }
        return true
    }

    private func insertPending(_ entry: PendingEntry) {
        let idx: Int
        if let slot = freeSlots.popLast() {
            idx = slot
            pending[slot] = entry
        } else {
            idx = pending.count
            pending.append(entry)
        }
        for i in entry.neighbors { inv[i].insert(idx) }
    }

    private func releasePending(_ idx: Int) {
        pending[idx] = nil
        freeSlots.append(idx)
    }

    /// 剥离传播：解出一个源块后沿倒排索引更新受影响的 pending 块
    private func propagate(_ index: Int, _ value: [UInt8]) {
        var queue: [(Int, [UInt8])] = [(index, value)]
        while let item = queue.popLast() {
            let s = item.0
            if solved[s] != nil { continue }
            solved[s] = item.1
            solvedTotal += 1
            note(.solved(index: s, data: item.1))

            let affected = inv[s]
            // 用赋空替代 removeAll：affected 还持着这个集合，removeAll 会为它复制一份内容
            inv[s] = []
            for idx in affected {
                guard pending[idx] != nil else { continue }
                // remove 返回 nil 即表示这条 pending 不含该源块，省掉一次 contains 查找
                guard pending[idx]!.neighbors.remove(s) != nil else { continue }
                // 必须原地改。先绑成局部 var 再写回的话，pending[idx] 仍持有同一缓冲区，
                // 异或会触发 COW，每条边白拷 T 字节——雪崩期有几十万条边
                ByteOps.xorInPlace(&pending[idx]!.payload, item.1)
                let degree = pending[idx]!.neighbors.count
                if degree == 1 {
                    let next = pending[idx]!.neighbors.first!
                    inv[next].remove(idx)
                    let payload = pending[idx]!.payload
                    releasePending(idx)
                    queue.append((next, payload))
                } else if degree == 0 {
                    releasePending(idx)
                }
            }
        }
    }

    /// 剥洋葱没有回代，拼接就是顺序拷贝，K=14316 时实测 Debug 也只要 4 ms
    func assemble(progress: ((Double) -> Void)?, isCancelled: () -> Bool) -> [UInt8]? {
        if isCancelled() { return nil }
        var result = [UInt8]()
        result.reserveCapacity(K * T)
        for i in 0..<K {
            result.append(contentsOf: solved[i] ?? [UInt8](repeating: 0, count: T))
        }
        progress?(1.0)
        return result
    }

    func releaseStorage() {
        solved = []
        pending = []
        freeSlots = []
        inv = []
        seen = []
        journal = []
        released = true
    }

    // MARK: 持久化

    func takeJournal() -> [ProgressRecord] {
        defer { journal.removeAll(keepingCapacity: true) }
        return journal
    }

    var journalCount: Int { journal.count }

    /// 压实：已被剥离的 rawBlock 记录在这里消失，仍活着的收敛成一条 pending 残值
    func snapshotRecords() -> [ProgressRecord] {
        guard !released else { return [] }
        var out: [ProgressRecord] = []
        out.reserveCapacity(solvedTotal + pendingCount + 1)
        for i in 0..<K {
            if let d = solved[i] { out.append(.solved(index: i, data: d)) }
        }
        for entry in pending {
            guard let e = entry else { continue }
            out.append(.pending(blockId: e.blockId, neighbors: e.neighbors.sorted(), payload: e.payload))
        }
        if let map = ProgressRecord.seenMap(of: seen) { out.append(map) }
        return out
    }

    var snapshotByteEstimate: Int {
        guard !released else { return 0 }
        return solvedTotal * (4 + T) + pendingCount * (T + 48) + seen.count / 8 + 64
    }

    /// 重放顺序有讲究：源块是终态必须先落位，pending 残值与原始块都要在它之上重建，
    /// 而纯 seen 记录最后补，否则 rawBlock 会被去重挡掉。
    @discardableResult
    func replay(_ records: [ProgressRecord]) -> Int {
        replaying = true
        defer {
            replaying = false
            journal.removeAll(keepingCapacity: true)
        }
        var dropped = 0

        for case let .solved(index, data) in records {
            guard index >= 0, index < K, data.count == T else { dropped += 1; continue }
            if solved[index] == nil { solvedTotal += 1 }
            solved[index] = data
        }

        // checkpoint 的 pending 残值：邻居可由 blockId 重算，存下来只作 PRNG 一致性自检
        for case let .pending(blockId, neighbors, payload) in records {
            guard payload.count == T, !neighbors.isEmpty else { dropped += 1; continue }
            let recomputed = composer.neighborsOf(blockId).filter { solved[$0] == nil }
            guard recomputed == neighbors else { dropped += 1; continue }
            guard seen.insert(blockId).inserted else { continue }
            if neighbors.count == 1 {
                propagate(neighbors[0], payload)
            } else {
                insertPending(PendingEntry(blockId: blockId, neighbors: Set(neighbors), payload: payload))
            }
        }

        // 日志里的原始块：走正常 add，对已落位的源块重新消元，重现存盘那一刻的残值。
        // 异或次数与当初增量降度时完全相同，没有多做一次
        for case let .rawBlock(blockId, payload) in records {
            guard payload.count == T else { dropped += 1; continue }
            _ = add(blockId: blockId, payload: payload[...])
        }

        replaySeen(records, into: &seen)
        return dropped
    }
}

// MARK: - 共用

/// 把 seen / seenMap 记录并回 blockId 集合
private func replaySeen(_ records: [ProgressRecord], into seen: inout Set<UInt32>) {
    for record in records {
        switch record {
        case .seen(let blockId):
            seen.insert(blockId)
        case .seenMap(let base, let bitCount, let bits):
            for off in 0..<bitCount where off >> 3 < bits.count {
                if bits[off >> 3] & (UInt8(1) << UInt8(off & 7)) != 0 {
                    seen.insert(base &+ UInt32(off))
                }
            }
        default:
            break
        }
    }
}
