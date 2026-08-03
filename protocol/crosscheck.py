#!/usr/bin/env python3
"""跨语言一致性校验：拿一端真实产出的帧字节，用参考实现解码并比对哈希。

帧转储格式（两端都要能产出）：连续的 [4 字节大端长度][帧字节] 记录，无文件头。

用法：
    python3 crosscheck.py <frames.dump> --sha <期望的原始文件 sha256 hex> [--drop 0.3] [--seed 1]

退出码 0 表示还原成功且哈希一致。
"""

import argparse
import hashlib
import struct
import sys

import refimpl as R


def read_dump(path):
    frames = []
    with open(path, "rb") as f:
        blob = f.read()
    off = 0
    while off + 4 <= len(blob):
        (n,) = struct.unpack(">I", blob[off:off + 4])
        off += 4
        if off + n > len(blob):
            raise ValueError("帧转储在第 %d 帧处截断" % len(frames))
        frames.append(blob[off:off + n])
        off += n
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("--sha", required=True, help="期望的原始文件 SHA-256（hex）")
    ap.add_argument("--name", default=None, help="期望的文件名，可选")
    ap.add_argument("--drop", type=float, default=0.0, help="模拟整帧丢失率")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    frames = read_dump(args.dump)
    print("读入 %d 帧" % len(frames))

    dec = None
    sid = K = T = codec = None
    compressed = False
    accepted = rejected = dup = 0
    max_block_id = 0
    st = R.mix32(args.seed ^ 0xABCD1234)

    for raw in frames:
        st = R.xorshift32(st)
        if (st / 4294967296.0) < args.drop:
            continue
        p = R.parse_frame(raw)
        if p is None:
            rejected += 1
            continue
        f_sid, f_K, f_T, f_codec, f_comp, base, m, blocks = p
        if dec is None:
            sid, K, T, codec, compressed = f_sid, f_K, f_T, f_codec, f_comp
            cdf = R.rs_cdf_q(K) if codec == R.CODEC_LT else None
            dec = (R.LinearSolveDecoder(K, T) if codec == R.CODEC_RLNC
                   else R.PeelingDecoder(K, T, cdf))
            print("会话 sessionId=%08x K=%d T=%d m=%d codec=%s compressed=%s"
                  % (sid, K, T, m,
                     "解方程" if codec == R.CODEC_RLNC else "剥洋葱", compressed))
        elif (f_sid, f_K, f_T, f_codec) != (sid, K, T, codec):
            print("警告：帧参数与首帧不一致，跳过", file=sys.stderr)
            rejected += 1
            continue
        accepted += 1
        for i, blk in enumerate(blocks):
            bid = (base + i) & R.MASK
            max_block_id = max(max_block_id, bid)
            if not dec.add(bid, blk):
                dup += 1
        if dec.complete:
            break

    if dec is None or not dec.complete:
        solved = 0 if dec is None else (
            len(dec.solved) if isinstance(dec, R.PeelingDecoder) else len(dec.basis))
        print("解码未完成：已解出 %d / %d" % (solved, K or 0), file=sys.stderr)
        return 2

    stream = dec.assemble()
    name, osize, psize, digest, comp, content = R.parse_stream(stream)
    got = hashlib.sha256(content).hexdigest()

    print("帧 通过=%d 拒绝=%d 重复块=%d 最大blockId=%d" % (accepted, rejected, dup, max_block_id))
    print("流内声明 sha256=%s" % digest.hex())
    print("还原内容 sha256=%s" % got)
    print("文件名=%s 原始大小=%d 载荷大小=%d 压缩=%s" % (name, osize, psize, comp))

    ok = (got == args.sha.lower() and digest.hex() == args.sha.lower()
          and len(content) == osize)
    if args.name is not None and name != args.name:
        print("文件名不匹配：期望 %s" % args.name, file=sys.stderr)
        ok = False
    print("结果：%s" % ("一致" if ok else "不一致"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
