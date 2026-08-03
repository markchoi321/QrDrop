package org.file.qrcode.protocol;

/**
 * 解方程方案（RLNC，codec = 0）的系数向量推导，CONTRACT.md 3.1。
 *
 * 每个 32 位字独立经 mix32 非线性混淆。严禁改用 xorshift32 连续输出拼接——
 * 它是 GF(2) 线性变换，向量全落在 32 维子空间内，秩永远停在 32。
 */
public final class LinearSolveComposer implements BlockComposer {

    private static final int GOLDEN = 0x9E3779B9;

    private final int K;
    private final int words;

    public LinearSolveComposer(int K) {
        if (K < 1) {
            throw new IllegalArgumentException("K 必须 >= 1");
        }
        this.K = K;
        this.words = (K + 31) >>> 5;
    }

    /** 返回 K 位系数位集，低位字在前；bit p 为 1 表示源块 p 参与异或。 */
    public int[] coeffWords(int blockId) {
        int base = Prng.mix32(blockId);
        int[] bits = new int[words];
        for (int i = 0; i < words; i++) {
            bits[i] = Prng.mix32(base ^ (i * GOLDEN));
        }
        // 截断到 K 位
        int rem = K & 31;
        if (rem != 0) {
            bits[words - 1] &= (int) ((1L << rem) - 1);
        }
        // 全零兜底：全零块不携带任何信息，强制置位 blockId mod K（无符号取模）
        boolean zero = true;
        for (int i = 0; i < words; i++) {
            if (bits[i] != 0) {
                zero = false;
                break;
            }
        }
        if (zero) {
            int p = (int) (Integer.toUnsignedLong(blockId) % K);
            bits[p >>> 5] |= 1 << (p & 31);
        }
        return bits;
    }

    /** 系数位集的小端字节表示，长度 ceil(K/8)，仅用于测试向量比对。 */
    public byte[] coeffBytes(int blockId) {
        int[] bits = coeffWords(blockId);
        byte[] out = new byte[(K + 7) >>> 3];
        for (int j = 0; j < out.length; j++) {
            out[j] = (byte) (bits[j >>> 2] >>> ((j & 3) << 3));
        }
        return out;
    }

    @Override
    public int[] neighborsOf(int blockId) {
        int[] bits = coeffWords(blockId);
        int count = 0;
        for (int i = 0; i < words; i++) {
            count += Integer.bitCount(bits[i]);
        }
        int[] out = new int[count];
        int n = 0;
        for (int i = 0; i < words; i++) {
            int w = bits[i];
            while (w != 0) {
                int b = Integer.numberOfTrailingZeros(w);
                out[n++] = (i << 5) + b;
                w &= w - 1;
            }
        }
        return out;
    }
}
