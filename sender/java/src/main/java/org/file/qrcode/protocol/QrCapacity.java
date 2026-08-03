package org.file.qrcode.protocol;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * QR 版本容量表与档位生成（CONTRACT.md 第 1 / 9 节）。
 *
 * 容量表是 ECC=L 字节模式的载荷上限，两端必须内置同一张表。
 */
public final class QrCapacity {

    /** QR 版本 -> ECC=L 字节模式容量（字节） */
    private static final int[] CAPACITY = {
            0,
            17, 32, 53, 78, 106, 134, 154, 192, 230, 271,
            321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
            929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732,
            1840, 1952, 2068, 2188, 2303, 2431, 2563, 2699, 2809, 2953
    };

    public static final int MAX_VERSION = 40;
    public static final int MAX_CAPACITY = 2953;
    /** 最低档容量下限，产品要求 */
    public static final int MIN_TIER_CAPACITY = 512;
    public static final int FRAME_HEADER_LEN = 20;
    public static final int MAX_TIERS = 10;

    private QrCapacity() {
    }

    public static int capacityOf(int version) {
        return CAPACITY[version];
    }

    /** 模块数（每边） */
    public static int modulesOf(int version) {
        return 17 + 4 * version;
    }

    /** 一个档位：QR 版本 + 容量 + 每帧编码块数 m */
    public static final class Tier {
        public final int version;
        public final int capacity;
        public final int m;

        Tier(int version, int capacity, int m) {
            this.version = version;
            this.capacity = capacity;
            this.m = m;
        }

        /** 实际载荷率 = m*T / capacity */
        public double payloadRate(int T) {
            return (double) m * T / capacity;
        }
    }

    /** 按契约第 9 节生成档位表，m 升序。 */
    public static List<Tier> buildTiers(int T) {
        int need = Math.max(MIN_TIER_CAPACITY, FRAME_HEADER_LEN + T);
        // 同一 m 只保留最小版本：更大的版本装不下更多块，只是白增模块数
        Map<Integer, Integer> byM = new TreeMap<Integer, Integer>();
        for (int v = 1; v <= MAX_VERSION; v++) {
            int p = CAPACITY[v];
            if (p < need) {
                continue;
            }
            int m = (p - FRAME_HEADER_LEN) / T;
            if (m < 1) {
                continue;
            }
            if (!byM.containsKey(m)) {
                byM.put(m, v);
            }
        }
        List<Tier> tiers = new ArrayList<Tier>();
        for (Map.Entry<Integer, Integer> e : byM.entrySet()) {
            int v = e.getValue();
            tiers.add(new Tier(v, CAPACITY[v], e.getKey()));
        }
        if (tiers.size() <= MAX_TIERS) {
            return tiers;
        }

        // 超过 10 档时按 m 的对数等比抽取，保证首尾必取
        int lo = tiers.get(0).m;
        int hi = tiers.get(tiers.size() - 1).m;
        List<Integer> chosen = new ArrayList<Integer>();
        for (int j = 0; j < MAX_TIERS; j++) {
            double target = lo * Math.pow((double) hi / lo, (double) j / (MAX_TIERS - 1));
            int i = 0;
            while (i < tiers.size() && tiers.get(i).m < target) {
                i++;
            }
            if (i >= tiers.size()) {
                i = tiers.size() - 1;
            }
            while (chosen.contains(i)) {
                i++;
            }
            if (i < tiers.size()) {
                chosen.add(i);
            }
        }
        // 抽取过程中被挤掉的名额从尾部未选者回填
        int i = tiers.size() - 1;
        while (chosen.size() < MAX_TIERS && i >= 0) {
            if (!chosen.contains(i)) {
                chosen.add(i);
            }
            i--;
        }
        Collections.sort(chosen);
        List<Tier> out = new ArrayList<Tier>();
        for (int idx : chosen) {
            out.add(tiers.get(idx));
        }
        return out;
    }
}
