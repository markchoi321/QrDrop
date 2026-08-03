package org.file.qrcode.protocol;

import java.util.Arrays;

/**
 * 剥洋葱方案（LT，codec = 1）的邻居集合推导，CONTRACT.md 4.3。
 *
 * 先按 Robust Soliton 抽度数，再用拒绝采样抽 d 个互异索引。
 * state mod K 有模偏，但两端一致且 K << 2^32，偏差可忽略。
 */
public final class PeelingComposer implements BlockComposer {

    private final int K;
    private final RobustSoliton soliton;

    public PeelingComposer(int K) {
        this.K = K;
        this.soliton = new RobustSoliton(K);
    }

    public RobustSoliton getSoliton() {
        return soliton;
    }

    @Override
    public int[] neighborsOf(int blockId) {
        int state = Prng.mix32(blockId);
        long packed = soliton.sampleDegree(state);
        int d = (int) (packed >>> 32);
        state = (int) packed;
        if (d > K) {
            d = K;
        }
        // 拒绝采样直到集齐 d 个互异索引；不做任何度数截断
        boolean[] taken = new boolean[K];
        int[] picked = new int[d];
        int n = 0;
        while (n < d) {
            state = Prng.xorshift32(state);
            // Java 无符号取模
            int idx = (int) (Integer.toUnsignedLong(state) % K);
            if (!taken[idx]) {
                taken[idx] = true;
                picked[n++] = idx;
            }
        }
        Arrays.sort(picked);
        return picked;
    }
}
