package org.file.qrcode.protocol;

/**
 * Robust Soliton 度分布（CONTRACT.md 4.1 / 4.2）。
 *
 * 关键点：ln 结果量化到 2^-16 网格（lnq），把跨平台 libm 的 ulp 级差异挡在网格之外；
 * 其余全部是 IEEE 双精度加减乘除，逐位确定。CDF 量化成 uint32，用 long 承载
 * （末档是 2^32，放不进 uint32），抽样全程整数比较。
 */
public final class RobustSoliton {

    public static final double C = 0.03;
    public static final double DELTA = 0.05;
    private static final double LN_GRID = 65536.0;
    /** 2^32，末档兜底值 */
    public static final long TWO_POW_32 = 4294967296L;

    private final int K;
    /** 长度 K+1，下标 0 不用 */
    private final long[] cdf;

    public RobustSoliton(int K) {
        if (K < 1) {
            throw new IllegalArgumentException("K 必须 >= 1");
        }
        this.K = K;
        this.cdf = buildCdf(K, C, DELTA);
    }

    /** 量化对数：floor(ln(x) * 65536 + 0.5) / 65536 */
    static double lnq(double x) {
        return Math.floor(Math.log(x) * LN_GRID + 0.5) / LN_GRID;
    }

    /** 按契约 4.2 计算量化 CDF，返回长度 K+1 的数组。 */
    static long[] buildCdf(int K, double c, double delta) {
        double[] rho = new double[K + 2];
        rho[1] = 1.0 / K;
        for (int d = 2; d <= K; d++) {
            rho[d] = 1.0 / ((double) d * (d - 1));
        }

        double R = c * lnq(K / delta) * Math.sqrt(K);
        double[] tau = new double[K + 2];
        int kr = (int) (K / R);
        if (kr < 1) {
            kr = 1;
        }
        int lim = Math.min(kr, K + 1);
        for (int d = 1; d < lim; d++) {
            tau[d] = R / ((double) d * K);
        }
        if (kr <= K) {
            double v = R * lnq(R / delta) / K;
            tau[kr] = v > 0.0 ? v : 0.0;
        }

        // 升序累加，顺序不可改
        double Z = 0.0;
        for (int d = 1; d <= K; d++) {
            Z += rho[d] + tau[d];
        }

        long[] cdf = new long[K + 1];
        double acc = 0.0;
        for (int d = 1; d <= K; d++) {
            acc += (rho[d] + tau[d]) / Z;
            long q = (long) (acc * 4294967296.0);
            if (q > 0xFFFFFFFFL) {
                q = TWO_POW_32;
            }
            cdf[d] = q;
        }
        cdf[K] = TWO_POW_32;
        return cdf;
    }

    public int getK() {
        return K;
    }

    /** 取度数 d 对应的量化 CDF 值，d 从 1 起。 */
    public long cdfAt(int d) {
        return cdf[d];
    }

    /**
     * 抽度数。先推进 state，再在 CDF 上二分。
     *
     * Java 无多返回值，把结果打包进一个 long：高 32 位是度数，低 32 位是推进后的 state。
     */
    public long sampleDegree(int state) {
        int next = Prng.xorshift32(state);
        long r = next & 0xFFFFFFFFL;
        int lo = 1;
        int hi = K;
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (cdf[mid] <= r) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return ((long) lo << 32) | (next & 0xFFFFFFFFL);
    }
}
