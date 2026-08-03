//
//  Decoders.swift
//  QrDrop
//
//  L3 解码器：解方程（增量高斯消元）与剥洋葱（BP 剥离）。
//  对应 CONTRACT.md 第 3.2 / 4.4 节。剥离解码维护倒排索引，避免传播步全表扫描。
//

import Foundation

/// 未消解编码块的持久化记录。
/// 解方程会话中语义不同：blockId 存 pivot 索引，neighbors 存系数向量置 1 的索引。
struct PendingRecord {
    let blockId: UInt32
    let neighbors: [Int]
    let payload: [UInt8]
}

struct SolvedRecord {
    let index: Int
    let data: [UInt8]
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

    func snapshotSolved() -> [SolvedRecord]
    func snapshotPending() -> [PendingRecord]
    /// 返回被自检丢弃的 pending 记录数
    @discardableResult
    func restore(solved: [SolvedRecord], pending: [PendingRecord]) -> Int
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
        released = true
    }

    /// 解方程会话没有中间态的源块，全部状态都在消元基里
    func snapshotSolved() -> [SolvedRecord] { [] }

    func snapshotPending() -> [PendingRecord] {
        guard !released else { return [] }
        var out: [PendingRecord] = []
        out.reserveCapacity(rank)
        for p in 0..<K {
            guard let c = basisCoeff[p], let d = basisData[p] else { continue }
            out.append(PendingRecord(blockId: UInt32(p), neighbors: c.indices, payload: d))
        }
        return out
    }

    @discardableResult
    func restore(solved: [SolvedRecord], pending: [PendingRecord]) -> Int {
        var dropped = 0
        for rec in pending {
            let p = Int(rec.blockId)
            guard p >= 0, p < K, rec.payload.count == T else { dropped += 1; continue }
            var c = BitSet(bitCount: K)
            var ok = true
            for i in rec.neighbors {
                if i < 0 || i >= K { ok = false; break }
                c.set(i)
            }
            // pivot 必须是系数向量的最高位，否则文件已损坏
            guard ok, c.highestBit == p else { dropped += 1; continue }
            if basisCoeff[p] == nil { rank += 1 }
            basisCoeff[p] = c
            basisData[p] = rec.payload
        }
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

    func add(blockId: UInt32, payload: ArraySlice<UInt8>) -> Bool {
        guard seen.insert(blockId).inserted else { return false }
        var pay = Array(payload)
        var remaining = Set<Int>()
        for i in composer.neighborsOf(blockId) {
            if let s = solved[i] {
                ByteOps.xorInPlace(&pay, s)
            } else {
                remaining.insert(i)
            }
        }
        if remaining.isEmpty { return true }
        if remaining.count == 1 {
            propagate(remaining.first!, pay)
        } else {
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

            let affected = inv[s]
            inv[s].removeAll()
            for idx in affected {
                guard var ent = pending[idx], ent.neighbors.contains(s) else { continue }
                ent.neighbors.remove(s)
                ByteOps.xorInPlace(&ent.payload, item.1)
                if ent.neighbors.count == 1 {
                    let next = ent.neighbors.first!
                    inv[next].remove(idx)
                    releasePending(idx)
                    queue.append((next, ent.payload))
                } else if ent.neighbors.isEmpty {
                    releasePending(idx)
                } else {
                    pending[idx] = ent
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
        released = true
    }

    func snapshotSolved() -> [SolvedRecord] {
        guard !released else { return [] }
        var out: [SolvedRecord] = []
        out.reserveCapacity(solvedTotal)
        for i in 0..<K {
            if let d = solved[i] { out.append(SolvedRecord(index: i, data: d)) }
        }
        return out
    }

    func snapshotPending() -> [PendingRecord] {
        guard !released else { return [] }
        var out: [PendingRecord] = []
        for entry in pending {
            guard let e = entry else { continue }
            out.append(PendingRecord(blockId: e.blockId, neighbors: e.neighbors.sorted(), payload: e.payload))
        }
        return out
    }

    @discardableResult
    func restore(solved solvedRecords: [SolvedRecord], pending pendingRecords: [PendingRecord]) -> Int {
        for rec in solvedRecords {
            guard rec.index >= 0, rec.index < K, rec.data.count == T else { continue }
            if solved[rec.index] == nil { solvedTotal += 1 }
            solved[rec.index] = rec.data
        }
        var dropped = 0
        for rec in pendingRecords {
            guard rec.payload.count == T else { dropped += 1; continue }
            // 自检：重算邻居集合并剔除已解出源块，应与存下来的完全一致
            let recomputed = composer.neighborsOf(rec.blockId).filter { solved[$0] == nil }
            guard recomputed == rec.neighbors, rec.neighbors.count >= 1 else { dropped += 1; continue }
            seen.insert(rec.blockId)
            if rec.neighbors.count == 1 {
                propagate(rec.neighbors[0], rec.payload)
            } else {
                insertPending(PendingEntry(blockId: rec.blockId,
                                           neighbors: Set(rec.neighbors),
                                           payload: rec.payload))
            }
        }
        return dropped
    }
}
