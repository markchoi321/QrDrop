package org.file.qrcode.protocol;

/**
 * 选参算法（CONTRACT.md 第 5 节）。
 *
 * 输入流长度，输出 (codec, T, K, m@V40, frames)。
 * 并列取舍顺序：帧数最少 -> T 最小 -> 解方程优先。这个顺序是契约固定的，
 * 因为 sessionId 依赖选参结果，必须确定性。
 */
public final class ParamPicker {

    public static final int CODEC_RLNC = 0;
    public static final int CODEC_LT = 1;

    public static final int T_MIN = 16;
    public static final int T_MAX = 500;
    /** 约束一：实时消元算力 */
    public static final int K_MAX_RLNC = 2720;
    /** 约束四：邻居表元数据不超过数据 */
    public static final int T_MIN_LT = 293;

    private ParamPicker() {
    }

    public static double epsRlnc(int K) {
        return K <= 1 ? 0.0 : 2.0 / K;
    }

    public static double epsLt(int K) {
        return K <= 1 ? 0.0 : 1.85 / Math.pow(K, 0.37);
    }

    /** 编码方案对应的额外开销 ε */
    public static double epsOf(int codec, int K) {
        return codec == CODEC_RLNC ? epsRlnc(K) : epsLt(K);
    }

    /** 选参结果 */
    public static final class Params {
        public final int codec;
        public final int T;
        public final int K;
        /** V40 下的每帧块数，仅用于选参与帧数估算 */
        public final int mAtV40;
        public final int frames;

        Params(int codec, int T, int K, int mAtV40, int frames) {
            this.codec = codec;
            this.T = T;
            this.K = K;
            this.mAtV40 = mAtV40;
            this.frames = frames;
        }
    }

    public static Params pick(long streamLen) {
        int bestFrames = Integer.MAX_VALUE;
        int bestT = 0;
        int bestCodec = 0;
        int bestK = 0;
        int bestM = 0;
        for (int T = T_MIN; T <= T_MAX; T++) {
            int K = (int) Math.max(1L, (streamLen + T - 1) / T);
            int m = (QrCapacity.MAX_CAPACITY - QrCapacity.FRAME_HEADER_LEN) / T;
            if (m < 1) {
                continue;
            }
            if (K <= K_MAX_RLNC && K <= 8 * T) {
                int need = (int) Math.ceil(K * (1.0 + epsRlnc(K)));
                int frames = (need + m - 1) / m;
                if (better(frames, T, CODEC_RLNC, bestFrames, bestT, bestCodec)) {
                    bestFrames = frames;
                    bestT = T;
                    bestCodec = CODEC_RLNC;
                    bestK = K;
                    bestM = m;
                }
            }
            if (T >= T_MIN_LT) {
                int need = (int) Math.ceil(K * (1.0 + epsLt(K)));
                int frames = (need + m - 1) / m;
                if (better(frames, T, CODEC_LT, bestFrames, bestT, bestCodec)) {
                    bestFrames = frames;
                    bestT = T;
                    bestCodec = CODEC_LT;
                    bestK = K;
                    bestM = m;
                }
            }
        }
        if (bestT == 0) {
            throw new IllegalStateException("选参失败，流长度不合法: " + streamLen);
        }
        return new Params(bestCodec, bestT, bestK, bestM, bestFrames);
    }

    /** 字典序比较 (frames, T, codec)，越小越好 */
    private static boolean better(int frames, int T, int codec,
                                  int bestFrames, int bestT, int bestCodec) {
        if (bestT == 0) {
            return true;
        }
        if (frames != bestFrames) {
            return frames < bestFrames;
        }
        if (T != bestT) {
            return T < bestT;
        }
        return codec < bestCodec;
    }
}
