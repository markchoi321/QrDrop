package org.file.qrcode.protocol;

/**
 * 跨语言 PRNG（CONTRACT.md 第 2 节）。
 *
 * 用 int 承载 uint32：所有右移必须写 >>>，乘法自然溢出即模 2^32。
 * 禁止使用 java.util.Random 等语言内置 RNG。
 */
public final class Prng {

    private Prng() {
    }

    /** lowbias32 finalizer，非线性混淆。 */
    public static int mix32(int x) {
        x ^= x >>> 16;
        x *= 0x7FEB352D;
        x ^= x >>> 15;
        x *= 0x846CA68B;
        x ^= x >>> 16;
        return x;
    }

    /** xorshift32 状态推进。0 是不动点，调用方须保证初值非零。 */
    public static int xorshift32(int s) {
        s ^= s << 13;
        s ^= s >>> 17;
        s ^= s << 5;
        return s;
    }
}
