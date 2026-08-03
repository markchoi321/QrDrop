package org.file.qrcode.protocol;

/**
 * 不依赖 JUnit 的向量比对入口，供离线环境下直接用 java 运行：
 *
 *   java -cp target/classes:target/test-classes org.file.qrcode.protocol.VectorCheck
 */
public final class VectorCheck {

    private static int failed = 0;

    private VectorCheck() {
    }

    public static void main(String[] args) {
        System.out.println("向量目录: " + VectorChecks.dir());
        run("prng.txt            mix32 / xorshift32", new Case() {
            public int run() {
                return VectorChecks.checkPrng();
            }
        });
        run("rs_cdf.txt          量化 CDF", new Case() {
            public int run() {
                return VectorChecks.checkRsCdf();
            }
        });
        run("lt_neighbors.txt    LT 邻居集合", new Case() {
            public int run() {
                return VectorChecks.checkLtNeighbors();
            }
        });
        run("rlnc_coeff.txt      RLNC 系数向量", new Case() {
            public int run() {
                return VectorChecks.checkRlncCoeff();
            }
        });
        run("params.txt          选参算法", new Case() {
            public int run() {
                return VectorChecks.checkParams();
            }
        });
        run("tiers.txt           档位表", new Case() {
            public int run() {
                return VectorChecks.checkTiers();
            }
        });
        run("deflate_*.bin       raw deflate", new Case() {
            public int run() {
                return VectorChecks.checkDeflate();
            }
        });
        run("stream.bin + e2e    流层 / sessionId", new Case() {
            public int run() {
                return VectorChecks.checkStreamAndSession();
            }
        });
        run("frames_rlnc.txt     整帧字节", new Case() {
            public int run() {
                return VectorChecks.checkFrames("rlnc");
            }
        });
        run("frames_lt.txt       整帧字节", new Case() {
            public int run() {
                return VectorChecks.checkFrames("lt");
            }
        });
        run("自测                流层压缩往返", new Case() {
            public int run() {
                return VectorChecks.checkStreamRoundTrip();
            }
        });

        if (failed == 0) {
            System.out.println("\n全部向量比对通过");
        } else {
            System.out.println("\n有 " + failed + " 项失败");
            System.exit(1);
        }
    }

    private interface Case {
        int run();
    }

    private static void run(String name, Case c) {
        try {
            int n = c.run();
            System.out.printf("  [通过] %-32s %d 项%n", name, n);
        } catch (Throwable t) {
            failed++;
            System.out.printf("  [失败] %-32s %s%n", name, t.getMessage());
        }
    }
}
