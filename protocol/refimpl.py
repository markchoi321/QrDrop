#!/usr/bin/env python3
"""QrDrop 协议 v1 参考实现 + 跨语言测试向量生成器。

本文件是 Java 发送端与 Swift 接收端的唯一权威语义来源。
两端实现必须逐位复现这里的输出，验证方式是跑 vectors/ 下的测试向量。

用法：
    python3 refimpl.py gen      重新生成 vectors/
    python3 refimpl.py check    自检（端到端 + 丢帧模拟）
"""

import hashlib
import math
import os
import struct
import sys
import zlib

MASK = 0xFFFFFFFF
HERE = os.path.dirname(os.path.abspath(__file__))
VEC = os.path.join(HERE, "vectors")

# ---------------------------------------------------------------- L1 物理层

# QR 版本 -> ECC=L 字节模式载荷容量（字节）。与设计文档 1.3 / 8.5 实测表一致。
QR_CAPACITY = {
    1: 17, 2: 32, 3: 53, 4: 78, 5: 106, 6: 134, 7: 154, 8: 192, 9: 230, 10: 271,
    11: 321, 12: 367, 13: 425, 14: 458, 15: 520, 16: 586, 17: 644, 18: 718,
    19: 792, 20: 858, 21: 929, 22: 1003, 23: 1091, 24: 1171, 25: 1273, 26: 1367,
    27: 1465, 28: 1528, 29: 1628, 30: 1732, 31: 1840, 32: 1952, 33: 2068,
    34: 2188, 35: 2303, 36: 2431, 37: 2563, 38: 2699, 39: 2809, 40: 2953,
}

MAX_CAPACITY = QR_CAPACITY[40]
MIN_TIER_CAPACITY = 512          # 最低档容量下限，产品要求（设计 10.4）
FRAME_HEADER_LEN = 20            # 设计 4.1
MAX_TIERS = 10


def qr_modules(version):
    """版本 -> 模块数（每边）。"""
    return 17 + 4 * version


def build_tiers(T):
    """按设计 10.4 生成档位表，返回 [(version, capacity, m), ...]，m 升序。"""
    need = max(MIN_TIER_CAPACITY, FRAME_HEADER_LEN + T)
    by_m = {}
    for v in range(1, 41):
        p = QR_CAPACITY[v]
        if p < need:
            continue
        m = (p - FRAME_HEADER_LEN) // T
        if m < 1:
            continue
        # 同一 m 只保留最小版本：更大的版本装不下更多块，只是白增模块数
        if m not in by_m:
            by_m[m] = v
    tiers = [(by_m[m], QR_CAPACITY[by_m[m]], m) for m in sorted(by_m)]
    if len(tiers) <= MAX_TIERS:
        return tiers
    # 超过 10 档时按 m 的对数等比抽取，保证首尾必取
    lo, hi = tiers[0][2], tiers[-1][2]
    chosen = []
    for j in range(MAX_TIERS):
        target = lo * (hi / lo) ** (j / (MAX_TIERS - 1))
        i = 0
        while i < len(tiers) and tiers[i][2] < target:
            i += 1
        if i >= len(tiers):
            i = len(tiers) - 1
        while i in chosen:
            i += 1
        if i < len(tiers):
            chosen.append(i)
    # 抽取过程中被挤掉的名额从尾部未选者回填
    i = len(tiers) - 1
    while len(chosen) < MAX_TIERS and i >= 0:
        if i not in chosen:
            chosen.append(i)
        i -= 1
    return [tiers[i] for i in sorted(chosen)]


# ------------------------------------------------------------------- PRNG

def mix32(x):
    """lowbias32 finalizer。设计 5.4，两端必须逐位一致。"""
    x &= MASK
    x ^= x >> 16
    x = (x * 0x7FEB352D) & MASK
    x ^= x >> 15
    x = (x * 0x846CA68B) & MASK
    x ^= x >> 16
    return x


def xorshift32(s):
    """状态推进。Java 侧右移必须用 >>>。设计 5.4。"""
    s &= MASK
    s ^= (s << 13) & MASK
    s ^= s >> 17
    s ^= (s << 5) & MASK
    return s


# --------------------------------------------------- L3 解方程方案（RLNC）

def rlnc_coeff(block_id, K):
    """由编码块序号推导 K 位系数向量，返回整数位集（bit i = 源块 i 参与异或）。

    每个 32 位字独立经 mix32 非线性混淆。严禁改用 xorshift32 连续输出拼接——
    它是 GF(2) 线性变换，所有向量落在 32 维子空间内，秩永远上不去（设计 5.2）。
    """
    base = mix32(block_id)
    bits = 0
    shift = 0
    i = 0
    while shift < K:
        bits |= mix32(base ^ ((i * 0x9E3779B9) & MASK)) << shift
        shift += 32
        i += 1
    bits &= (1 << K) - 1
    # 全零向量不携带任何信息；K 很小时（如直传退化的 K=1）出现概率不可忽略。
    # 兜底规则：强制置位 blockId mod K。两端必须一致。
    if bits == 0:
        bits = 1 << (block_id % K)
    return bits


def rlnc_neighbors(block_id, K):
    v = rlnc_coeff(block_id, K)
    out = []
    i = 0
    while v:
        if v & 1:
            out.append(i)
        v >>= 1
        i += 1
    return out


# ----------------------------------------------------- L3 剥洋葱方案（LT）

LT_C = 0.03      # 设计 8.2 实测最优区间 0.02–0.03
LT_DELTA = 0.05
LN_GRID = 65536.0   # ln 结果量化到 2^-16 网格，消除跨平台 libm 末位差异


def _ln_q(x):
    """量化对数：把跨语言 ln 实现的 ulp 级差异挡在网格之外。

    量化后 CDF 的其余运算全部是 IEEE 双精度的加减乘除，结果逐位确定。
    """
    return math.floor(math.log(x) * LN_GRID + 0.5) / LN_GRID


def rs_cdf_q(K, c=LT_C, delta=LT_DELTA):
    """Robust Soliton 累积分布，量化为 uint32 便于整数比较。

    返回长度 K+1 的数组，cdf_q[d] 对应度数 d（下标 0 不用）。
    抽样规则：r = next(state)，取最小的 d 使 r < cdf_q[d]；都不满足则 d = K。
    """
    rho = [0.0] * (K + 2)
    rho[1] = 1.0 / K
    for d in range(2, K + 1):
        rho[d] = 1.0 / (d * (d - 1))

    R = c * _ln_q(K / delta) * math.sqrt(K)
    tau = [0.0] * (K + 2)
    kr = max(1, int(K / R))
    for d in range(1, min(kr, K + 1)):
        tau[d] = R / (d * K)
    if kr <= K:
        tau[kr] = max(0.0, R * _ln_q(R / delta) / K)

    Z = 0.0
    for d in range(1, K + 1):
        Z += rho[d] + tau[d]

    cdf_q = [0] * (K + 1)
    acc = 0.0
    for d in range(1, K + 1):
        acc += (rho[d] + tau[d]) / Z
        q = int(acc * 4294967296.0)
        if q > MASK:
            q = MASK + 1
        cdf_q[d] = q
    cdf_q[K] = MASK + 1     # 末档兜底，保证一定命中
    return cdf_q


def lt_sample_degree(state, K, cdf_q):
    """返回 (度数 d, 推进后的 state)。二分查找 cdf_q。"""
    state = xorshift32(state)
    r = state
    lo, hi = 1, K
    while lo < hi:
        mid = (lo + hi) // 2
        if cdf_q[mid] <= r:
            lo = mid + 1
        else:
            hi = mid
    return lo, state


def lt_neighbors(block_id, K, cdf_q):
    """由编码块序号推导参与异或的源块索引集合（升序）。设计 5.3。"""
    state = mix32(block_id)
    d, state = lt_sample_degree(state, K, cdf_q)
    if d > K:
        d = K
    picked = set()
    # 拒绝采样：取模有偏但两端一致，K << 2^32 时偏差可忽略
    while len(picked) < d:
        state = xorshift32(state)
        picked.add(state % K)
    return sorted(picked)


# ------------------------------------------------------------ L3 选参算法

CODEC_RLNC = 0    # 解方程方案
CODEC_LT = 1      # 剥洋葱方案

T_MIN, T_MAX = 16, 500
K_MAX_RLNC = 2720          # 约束一：实时消元算力
T_MIN_LT = 293             # 约束四：邻居表元数据不超过数据


def eps_rlnc(K):
    return 0.0 if K <= 1 else 2.0 / K


def eps_lt(K):
    return 0.0 if K <= 1 else 1.85 / (K ** 0.37)


def pick_params(stream_len):
    """按设计 8.3 选参。返回 (codec, T, K, m_at_v40, frames)。

    并列时的取舍顺序：帧数最少 -> T 最小 -> 解方程优先。
    T 最小优先是为了换取更细的档位划分与更高的中高档载荷率（设计 8.5）。
    """
    best = None
    for T in range(T_MIN, T_MAX + 1):
        K = max(1, -(-stream_len // T))
        m = (MAX_CAPACITY - FRAME_HEADER_LEN) // T
        if m < 1:
            continue
        if K <= K_MAX_RLNC and K <= 8 * T:
            frames = -(-int(math.ceil(K * (1 + eps_rlnc(K)))) // m)
            cand = (frames, T, CODEC_RLNC, K, m)
            if best is None or cand < best:
                best = cand
        if T >= T_MIN_LT:
            frames = -(-int(math.ceil(K * (1 + eps_lt(K)))) // m)
            cand = (frames, T, CODEC_LT, K, m)
            if best is None or cand < best:
                best = cand
    frames, T, codec, K, m = best
    return codec, T, K, m, frames


# -------------------------------------------------------------- L4 流层

STREAM_MAGIC = b"VD"
STREAM_VERSION = 1
STREAM_HEADER_FIXED = 54


def deflate_raw(data):
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    return co.compress(data) + co.flush()


def inflate_raw(data):
    return zlib.decompress(data, -15)


def build_stream(content, file_name, allow_compress=True):
    """返回 (stream_bytes, compressed_flag)。设计 6.1 / 6.3。"""
    digest = hashlib.sha256(content).digest()
    payload = content
    compressed = False
    if allow_compress:
        packed = deflate_raw(content)
        # 压缩不变小则关闭：jpg/png/zip/mp4 上 deflate 会让数据变大
        if len(packed) < len(content):
            payload = packed
            compressed = True
    fn = file_name.encode("utf-8")
    hdr = (STREAM_MAGIC
           + bytes([STREAM_VERSION, 1 if compressed else 0])
           + struct.pack(">QQ", len(content), len(payload))
           + digest
           + struct.pack(">H", len(fn))
           + fn)
    assert len(hdr) == STREAM_HEADER_FIXED + len(fn)
    return hdr + payload, compressed


def parse_stream(stream):
    """返回 (file_name, original_size, payload_size, sha256, compressed, content)。"""
    if stream[0:2] != STREAM_MAGIC:
        raise ValueError("流头 magic 不匹配")
    version = stream[2]
    if version != STREAM_VERSION:
        raise ValueError("流格式版本不支持: %d" % version)
    flags = stream[3]
    compressed = bool(flags & 1)
    original_size, payload_size = struct.unpack(">QQ", stream[4:20])
    digest = stream[20:52]
    (fn_len,) = struct.unpack(">H", stream[52:54])
    file_name = stream[54:54 + fn_len].decode("utf-8")
    body = stream[54 + fn_len:54 + fn_len + payload_size]
    content = inflate_raw(body) if compressed else body
    return file_name, original_size, payload_size, digest, compressed, content


# ------------------------------------------------------------ L5 会话标识

def session_id(content_sha256, T, K, codec):
    """设计 7.2：确定性推导，使同一文件同一参数的重复传输天然续接。"""
    buf = (content_sha256
           + struct.pack(">H", T)
           + bytes([(K >> 16) & 0xFF, (K >> 8) & 0xFF, K & 0xFF])
           + bytes([codec]))
    return struct.unpack(">I", hashlib.sha256(buf).digest()[:4])[0]


# -------------------------------------------------------------- L2 帧层

FRAME_MAGIC = 0x56
PROTOCOL_VERSION = 1


def split_source_blocks(stream, K, T):
    padded = stream + b"\x00" * (K * T - len(stream))
    return [padded[i * T:(i + 1) * T] for i in range(K)]


def xor_blocks(src, idxs, T):
    out = bytearray(T)
    for i in idxs:
        b = src[i]
        for j in range(T):
            out[j] ^= b[j]
    return bytes(out)


def neighbors_of(block_id, K, codec, cdf_q):
    if codec == CODEC_RLNC:
        return rlnc_neighbors(block_id, K)
    return lt_neighbors(block_id, K, cdf_q)


def encode_frame(src, K, T, codec, compressed, sid, base_block_id, m, cdf_q):
    """产出完整一帧字节。设计 4.1。"""
    flags = (PROTOCOL_VERSION << 4) | ((1 if compressed else 0) << 3) | (codec << 2)
    body = bytearray()
    for i in range(m):
        bid = (base_block_id + i) & MASK
        body += xor_blocks(src, neighbors_of(bid, K, codec, cdf_q), T)
    head = bytearray(FRAME_HEADER_LEN)
    head[0] = FRAME_MAGIC
    head[1] = flags
    head[2:6] = struct.pack(">I", sid)
    head[6:9] = bytes([(K >> 16) & 0xFF, (K >> 8) & 0xFF, K & 0xFF])
    head[9:11] = struct.pack(">H", T)
    head[11] = m
    head[12:16] = struct.pack(">I", base_block_id & MASK)
    head[16:20] = struct.pack(">I", zlib.crc32(bytes(body)) & MASK)
    return bytes(head) + bytes(body)


def parse_frame(buf):
    """返回 (sid, K, T, codec, compressed, base_block_id, m, [块载荷...])；不合法返回 None。"""
    if len(buf) < FRAME_HEADER_LEN or buf[0] != FRAME_MAGIC:
        return None
    flags = buf[1]
    if (flags >> 4) != PROTOCOL_VERSION:
        return None
    compressed = bool((flags >> 3) & 1)
    codec = (flags >> 2) & 1
    (sid,) = struct.unpack(">I", buf[2:6])
    K = (buf[6] << 16) | (buf[7] << 8) | buf[8]
    (T,) = struct.unpack(">H", buf[9:11])
    m = buf[11]
    (base,) = struct.unpack(">I", buf[12:16])
    (crc,) = struct.unpack(">I", buf[16:20])
    body = buf[FRAME_HEADER_LEN:FRAME_HEADER_LEN + m * T]
    if len(body) != m * T or K == 0 or T == 0 or m == 0:
        return None
    if (zlib.crc32(body) & MASK) != crc:
        return None
    blocks = [body[i * T:(i + 1) * T] for i in range(m)]
    return sid, K, T, codec, compressed, base, m, blocks


# ------------------------------------------------------------ 解码器

class PeelingDecoder:
    """剥洋葱（BP）解码器。设计 5.6。"""

    def __init__(self, K, T, cdf_q):
        self.K, self.T, self.cdf_q = K, T, cdf_q
        self.solved = {}
        self.pending = []            # [neighbors:set, payload:bytearray] 或 None
        self.inv = {}                # 源块索引 -> pending 下标集合
        self.seen = set()

    def add(self, block_id, payload):
        if block_id in self.seen:
            return False
        self.seen.add(block_id)
        nb = set(lt_neighbors(block_id, self.K, self.cdf_q))
        pay = bytearray(payload)
        for i in list(nb):
            if i in self.solved:
                nb.discard(i)
                s = self.solved[i]
                for j in range(self.T):
                    pay[j] ^= s[j]
        if not nb:
            return True
        if len(nb) == 1:
            self._propagate(nb.pop(), bytes(pay))
        else:
            idx = len(self.pending)
            self.pending.append([nb, pay])
            for i in nb:
                self.inv.setdefault(i, set()).add(idx)
        return True

    def _propagate(self, index, value):
        queue = [(index, value)]
        while queue:
            s, val = queue.pop()
            if s in self.solved:
                continue
            self.solved[s] = val
            for idx in list(self.inv.pop(s, ())):
                ent = self.pending[idx]
                if ent is None or s not in ent[0]:
                    continue
                ent[0].discard(s)
                for j in range(self.T):
                    ent[1][j] ^= val[j]
                if len(ent[0]) == 1:
                    nxt = next(iter(ent[0]))
                    payload = bytes(ent[1])
                    self.pending[idx] = None
                    queue.append((nxt, payload))
                elif not ent[0]:
                    self.pending[idx] = None

    @property
    def complete(self):
        return len(self.solved) == self.K

    def assemble(self):
        return b"".join(self.solved[i] for i in range(self.K))


class LinearSolveDecoder:
    """解方程（RLNC）增量高斯消元解码器。设计 5.2。"""

    def __init__(self, K, T):
        self.K, self.T = K, T
        self.basis = {}              # pivot -> (系数位集, 数据)
        self.seen = set()

    def add(self, block_id, payload):
        if block_id in self.seen:
            return False
        self.seen.add(block_id)
        c = rlnc_coeff(block_id, self.K)
        d = bytearray(payload)
        while c:
            p = c.bit_length() - 1
            if p in self.basis:
                c2, d2 = self.basis[p]
                c ^= c2
                for j in range(self.T):
                    d[j] ^= d2[j]
            else:
                self.basis[p] = (c, bytes(d))
                break
        return True

    @property
    def complete(self):
        return len(self.basis) == self.K

    def assemble(self):
        # 回代：把上三角化简为单位阵
        out = {}
        for p in sorted(self.basis):
            c, d = self.basis[p]
            d = bytearray(d)
            c ^= 1 << p
            while c:
                q = c.bit_length() - 1
                c2, d2 = out[q]
                c ^= c2
                for j in range(self.T):
                    d[j] ^= d2[j]
            out[p] = (1 << p, bytes(d))
        return b"".join(out[i][1] for i in range(self.K))


# --------------------------------------------------------- 向量生成

def _hex(b):
    return b.hex()


def _det_bytes(n, seed):
    """确定性字节流，用于构造 fixture。"""
    out = bytearray()
    s = mix32(seed)
    while len(out) < n:
        s = xorshift32(s)
        out += struct.pack(">I", s)
    return bytes(out[:n])


def gen():
    os.makedirs(VEC, exist_ok=True)

    # 1. PRNG
    lines = ["# mix32 / xorshift32 测试向量（设计 5.4）", "# 格式: <函数> <输入 hex8> <输出 hex8>"]
    seeds = [0, 1, 2, 3, 7, 42, 255, 256, 65535, 65536, 0x9E3779B9,
             0x7FFFFFFF, 0x80000000, 0xDEADBEEF, 0xFFFFFFFF, 123456789]
    for s in seeds:
        lines.append("mix32 %08x %08x" % (s, mix32(s)))
    for s in seeds:
        v = s if s else 1        # xorshift32 的 0 是不动点，单独说明
        lines.append("xorshift32 %08x %08x" % (v, xorshift32(v)))
    # 链式推进，覆盖状态演化
    st = mix32(12345)
    for i in range(8):
        nxt = xorshift32(st)
        lines.append("xorshift32 %08x %08x" % (st, nxt))
        st = nxt
    _write("prng.txt", lines)

    # 2. Robust Soliton CDF（量化）
    lines = ["# Robust Soliton 量化 CDF，c=%.2f delta=%.2f（设计 5.5）" % (LT_C, LT_DELTA),
             "# 格式: <K> <d> <cdf_q 十进制>；cdf_q[K] 恒为 4294967296"]
    for K in (1, 2, 10, 100, 293, 1000, 7158):
        cdf = rs_cdf_q(K)
        ds = sorted({d for d in (1, 2, 3, 4, K // 2, K - 1, K) if 1 <= d <= K})
        for d in ds:
            lines.append("%d %d %d" % (K, d, cdf[d]))
    _write("rs_cdf.txt", lines)

    # 3. LT 邻居集合
    lines = ["# LT blockId -> (度数, 源块索引集合)（设计 5.3）",
             "# 格式: <K> <blockId> <degree> <idx,idx,...>"]
    for K in (10, 100, 293, 1000, 7158):
        cdf = rs_cdf_q(K)
        for bid in (0, 1, 2, 3, 17, 255, 4096, 65535, 1000000, 4294967295):
            nb = lt_neighbors(bid, K, cdf)
            lines.append("%d %d %d %s" % (K, bid, len(nb), ",".join(map(str, nb))))
    _write("lt_neighbors.txt", lines)

    # 4. RLNC 系数向量
    lines = ["# RLNC blockId -> K 位系数向量（设计 5.2）",
             "# 格式: <K> <blockId> <hex，低位在前，每字节承载 8 个源块索引>"]
    for K in (1, 2, 8, 32, 33, 100, 892, 1748):
        nbytes = (K + 7) // 8
        for bid in (0, 1, 2, 3, 17, 255, 4096, 65535, 1000000, 4294967295):
            v = rlnc_coeff(bid, K)
            raw = v.to_bytes(nbytes, "little")
            lines.append("%d %d %s" % (K, bid, raw.hex()))
    _write("rlnc_coeff.txt", lines)

    # 5. 选参算法
    lines = ["# 选参算法输出（设计 8.3）",
             "# 格式: <streamLen> <codec 0=解方程 1=剥洋葱> <T> <K> <m@V40> <frames>"]
    sizes = [100, 1024, 5 * 1024, 10 * 1024, 50 * 1024, 100 * 1024, 200 * 1024,
             500 * 1024, 1024 * 1024, 2 * 1024 * 1024, 4 * 1024 * 1024,
             8 * 1024 * 1024, 16 * 1024 * 1024, 512054, 1048650]
    for n in sizes:
        codec, T, K, m, frames = pick_params(n)
        lines.append("%d %d %d %d %d %d" % (n, codec, T, K, m, frames))
    _write("params.txt", lines)

    # 6. 档位表
    lines = ["# 档位生成规则输出（设计 10.4）",
             "# 格式: <T> <档位序号从1起> <QR版本> <容量> <每帧块数 m>"]
    for T in (26, 115, 293, 419, 500):
        for i, (v, cap, m) in enumerate(build_tiers(T), 1):
            lines.append("%d %d %d %d %d" % (T, i, v, cap, m))
    _write("tiers.txt", lines)

    # 7. deflate 往返（接收端只需 inflate 正确）
    text = (b"VisionDrop raw deflate roundtrip fixture. " * 400
            + _det_bytes(2000, 99))
    _write_bin("deflate_plain.bin", text)
    _write_bin("deflate_packed.bin", deflate_raw(text))

    # 8. 流层 + 帧层 + 端到端（不压缩，避免依赖 deflate 实现的字节级一致）
    content = _det_bytes(20000, 2026)
    _write_bin("fixture.bin", content)
    stream, compressed = build_stream(content, "fixture.bin", allow_compress=False)
    assert not compressed
    _write_bin("stream.bin", stream)

    meta = ["# 端到端 fixture 参数", "# 格式: <键> <值>"]
    meta.append("fileName fixture.bin")
    meta.append("contentLen %d" % len(content))
    meta.append("contentSha256 %s" % hashlib.sha256(content).hexdigest())
    meta.append("streamLen %d" % len(stream))
    meta.append("streamSha256 %s" % hashlib.sha256(stream).hexdigest())

    for codec_name, codec in (("rlnc", CODEC_RLNC), ("lt", CODEC_LT)):
        # 固定 T 便于两端复现；rlnc 用选参算法的真实结果，lt 用其最小合法块大小
        if codec == CODEC_RLNC:
            picked, T, K, m, _frames = pick_params(len(stream))
            assert picked == CODEC_RLNC, "fixture 应落在解方程档"
        else:
            T = T_MIN_LT
            K = -(-len(stream) // T)
            m = (MAX_CAPACITY - FRAME_HEADER_LEN) // T
        sid = session_id(hashlib.sha256(content).digest(), T, K, codec)
        meta += ["%s.T %d" % (codec_name, T), "%s.K %d" % (codec_name, K),
                 "%s.m %d" % (codec_name, m), "%s.sessionId %08x" % (codec_name, sid)]

        cdf = rs_cdf_q(K) if codec == CODEC_LT else None
        src = split_source_blocks(stream, K, T)
        flines = ["# %s 帧字节向量。源数据 = stream.bin，T=%d K=%d m=%d sessionId=%08x"
                  % (codec_name, T, K, m, sid),
                  "# 格式: <baseBlockId> <整帧 hex>"]
        for f in range(6):
            base = f * m
            frame = encode_frame(src, K, T, codec, False, sid, base, m, cdf)
            flines.append("%d %s" % (base, _hex(frame)))
        _write("frames_%s.txt" % codec_name, flines)

    _write("e2e.txt", meta)
    print("向量已写入 %s" % VEC)


def _write(name, lines):
    with open(os.path.join(VEC, name), "w") as f:
        f.write("\n".join(lines) + "\n")


def _write_bin(name, data):
    with open(os.path.join(VEC, name), "wb") as f:
        f.write(data)


# ------------------------------------------------------------------ 自检

def _run_session(content, file_name, codec_force=None, drop=0.0, seed=1):
    stream, compressed = build_stream(content, file_name)
    codec, T, K, m, _ = pick_params(len(stream))
    if codec_force is not None and codec_force != codec:
        codec = codec_force
        if codec == CODEC_LT:
            T = max(T, T_MIN_LT)
        K = -(-len(stream) // T)
        m = (MAX_CAPACITY - FRAME_HEADER_LEN) // T
    sid = session_id(hashlib.sha256(content).digest(), T, K, codec)
    cdf = rs_cdf_q(K) if codec == CODEC_LT else None
    src = split_source_blocks(stream, K, T)

    dec = (LinearSolveDecoder(K, T) if codec == CODEC_RLNC
           else PeelingDecoder(K, T, cdf))
    st = mix32(seed ^ 0xABCD1234)
    base, frames = 0, 0
    while not dec.complete:
        frame = encode_frame(src, K, T, codec, compressed, sid, base, m, cdf)
        frames += 1
        st = xorshift32(st)
        lost = (st / 4294967296.0) < drop
        if not lost:
            p = parse_frame(frame)
            assert p is not None
            for i, blk in enumerate(p[7]):
                dec.add((base + i) & MASK, blk)
        base += m
        if frames > K * 20:
            return None
    got = dec.assemble()
    name, osize, psize, digest, comp, recovered = parse_stream(got)
    ok = (name == file_name and hashlib.sha256(recovered).digest() == digest
          and recovered == content)
    return frames, len(dec.seen), ok, codec, T, K, m, compressed


def check():
    print("=== 选参算法对照设计 8.4 ===")
    for label, n in (("500 KB", 500 * 1024 + 74), ("1 MB", 1024 * 1024 + 74),
                     ("2 MB", 2 * 1024 * 1024 + 74), ("100 KB", 100 * 1024 + 74)):
        codec, T, K, m, frames = pick_params(n)
        print("  %-7s -> %s T=%d K=%d m=%d frames=%d (%.1fs @100ms)"
              % (label, "解方程" if codec == CODEC_RLNC else "剥洋葱",
                 T, K, m, frames, frames * 0.1))

    print("\n=== 端到端（含压缩），文本文件 ===")
    text = (b"the quick brown fox jumps over the lazy dog\n" * 900)
    for drop in (0.0, 0.1, 0.3, 0.5):
        r = _run_session(text, "text.txt", drop=drop, seed=int(drop * 100) + 1)
        assert r and r[2], "还原失败 drop=%s" % drop
        print("  丢帧 %3.0f%% | %d 帧 | 收 %d 块 | K=%d T=%d %s | 压缩=%s | 哈希一致"
              % (drop * 100, r[0], r[1], r[5], r[4],
                 "解方程" if r[3] == CODEC_RLNC else "剥洋葱", r[7]))

    print("\n=== 端到端（不可压缩随机数据），强制两种编码 ===")
    rnd = _det_bytes(60000, 7)
    for codec in (CODEC_RLNC, CODEC_LT):
        r = _run_session(rnd, "rand.bin", codec_force=codec, drop=0.2, seed=9)
        assert r and r[2], "还原失败"
        eps = r[1] / r[5] - 1
        print("  %s | %d 帧 | 收 %d 块 | K=%d | 实测 ε=%.2f%% | 哈希一致"
              % ("解方程" if codec == CODEC_RLNC else "剥洋葱",
                 r[0], r[1], r[5], eps * 100))

    print("\n=== 档位表 T=293（对照设计 8.5）===")
    for i, (v, cap, m) in enumerate(build_tiers(293), 1):
        print("  档%2d V%-2d 容量%4d 每帧%2d块 载荷率%.1f%% 模块%d"
              % (i, v, cap, m, m * 293 * 100.0 / cap, qr_modules(v)))
    print("\n全部自检通过")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "gen":
        gen()
    else:
        check()
