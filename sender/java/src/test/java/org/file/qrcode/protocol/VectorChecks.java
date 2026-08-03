package org.file.qrcode.protocol;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * protocol/vectors 下全部测试向量的比对逻辑。
 *
 * 单独抽出来是为了让 JUnit 测试与可直接 java 运行的 VectorCheck 共用同一份实现，
 * 避免离线环境下 surefire 无法解析 provider 时测试变成摆设。
 * 任何一条不符即抛 AssertionError。
 */
public final class VectorChecks {

    private static File vectorsDir;

    private VectorChecks() {
    }

    // ---------------------------------------------------------- 向量目录定位

    /** 从当前工作目录逐级向上找 protocol/vectors */
    public static File dir() {
        if (vectorsDir != null) {
            return vectorsDir;
        }
        File cur = new File(System.getProperty("user.dir")).getAbsoluteFile();
        for (int i = 0; i < 8 && cur != null; i++) {
            File c = new File(cur, "protocol" + File.separator + "vectors");
            if (c.isDirectory()) {
                vectorsDir = c;
                return c;
            }
            cur = cur.getParentFile();
        }
        throw new IllegalStateException("找不到 protocol/vectors 目录，当前工作目录: "
                + System.getProperty("user.dir"));
    }

    private static List<String> lines(String name) {
        List<String> out = new ArrayList<String>();
        BufferedReader r = null;
        try {
            r = new BufferedReader(new InputStreamReader(
                    new FileInputStream(new File(dir(), name)), "UTF-8"));
            String s;
            while ((s = r.readLine()) != null) {
                s = s.trim();
                // '#' 开头是注释
                if (s.isEmpty() || s.charAt(0) == '#') {
                    continue;
                }
                out.add(s);
            }
        } catch (IOException e) {
            throw new IllegalStateException("读取向量失败: " + name, e);
        } finally {
            close(r);
        }
        return out;
    }

    private static byte[] bin(String name) {
        File f = new File(dir(), name);
        byte[] buf = new byte[(int) f.length()];
        FileInputStream in = null;
        try {
            in = new FileInputStream(f);
            int off = 0;
            while (off < buf.length) {
                int n = in.read(buf, off, buf.length - off);
                if (n < 0) {
                    break;
                }
                off += n;
            }
        } catch (IOException e) {
            throw new IllegalStateException("读取向量失败: " + name, e);
        } finally {
            close(in);
        }
        return buf;
    }

    private static void close(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (IOException ignored) {
                // 忽略
            }
        }
    }

    private static void need(boolean ok, String msg) {
        if (!ok) {
            throw new AssertionError(msg);
        }
    }

    static byte[] unhex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) {
            sb.append(String.format("%02x", x));
        }
        return sb.toString();
    }

    // ---------------------------------------------------------- 各项比对

    /** prng.txt -> mix32 / xorshift32 */
    public static int checkPrng() {
        int n = 0;
        for (String line : lines("prng.txt")) {
            String[] f = line.split("\\s+");
            int in = (int) Long.parseLong(f[1], 16);
            int want = (int) Long.parseLong(f[2], 16);
            int got = "mix32".equals(f[0]) ? Prng.mix32(in) : Prng.xorshift32(in);
            need(got == want, String.format("%s(%08x) 期望 %08x 实得 %08x",
                    f[0], in, want, got));
            n++;
        }
        return n;
    }

    /** rs_cdf.txt -> Robust Soliton 量化 CDF */
    public static int checkRsCdf() {
        Map<Integer, RobustSoliton> cache = new HashMap<Integer, RobustSoliton>();
        int n = 0;
        for (String line : lines("rs_cdf.txt")) {
            String[] f = line.split("\\s+");
            int K = Integer.parseInt(f[0]);
            int d = Integer.parseInt(f[1]);
            long want = Long.parseLong(f[2]);
            RobustSoliton rs = cache.get(K);
            if (rs == null) {
                rs = new RobustSoliton(K);
                cache.put(K, rs);
            }
            long got = rs.cdfAt(d);
            need(got == want, String.format("cdf[K=%d][d=%d] 期望 %d 实得 %d", K, d, want, got));
            n++;
        }
        return n;
    }

    /** lt_neighbors.txt -> LT 邻居集合 */
    public static int checkLtNeighbors() {
        Map<Integer, PeelingComposer> cache = new HashMap<Integer, PeelingComposer>();
        int n = 0;
        for (String line : lines("lt_neighbors.txt")) {
            String[] f = line.split("\\s+");
            int K = Integer.parseInt(f[0]);
            int blockId = (int) Long.parseLong(f[1]);
            int degree = Integer.parseInt(f[2]);
            int[] want = parseCsv(f.length > 3 ? f[3] : "");
            PeelingComposer c = cache.get(K);
            if (c == null) {
                c = new PeelingComposer(K);
                cache.put(K, c);
            }
            int[] got = c.neighborsOf(blockId);
            need(got.length == degree, String.format(
                    "LT K=%d blockId=%d 度数期望 %d 实得 %d", K, blockId, degree, got.length));
            need(Arrays.equals(got, want), String.format(
                    "LT K=%d blockId=%d 邻居期望 %s 实得 %s",
                    K, blockId, Arrays.toString(want), Arrays.toString(got)));
            n++;
        }
        return n;
    }

    private static int[] parseCsv(String s) {
        if (s.isEmpty()) {
            return new int[0];
        }
        String[] parts = s.split(",");
        int[] out = new int[parts.length];
        for (int i = 0; i < parts.length; i++) {
            out[i] = Integer.parseInt(parts[i]);
        }
        return out;
    }

    /** rlnc_coeff.txt -> RLNC 系数向量（向量文件里是小端 hex） */
    public static int checkRlncCoeff() {
        Map<Integer, LinearSolveComposer> cache = new HashMap<Integer, LinearSolveComposer>();
        int n = 0;
        for (String line : lines("rlnc_coeff.txt")) {
            String[] f = line.split("\\s+");
            int K = Integer.parseInt(f[0]);
            int blockId = (int) Long.parseLong(f[1]);
            LinearSolveComposer c = cache.get(K);
            if (c == null) {
                c = new LinearSolveComposer(K);
                cache.put(K, c);
            }
            String got = hex(c.coeffBytes(blockId));
            need(got.equals(f[2]), String.format(
                    "RLNC K=%d blockId=%d 期望 %s 实得 %s", K, blockId, f[2], got));
            // 邻居集合必须与位集一致
            int[] nb = c.neighborsOf(blockId);
            byte[] raw = unhex(f[2]);
            int cnt = 0;
            for (byte b : raw) {
                cnt += Integer.bitCount(b & 0xFF);
            }
            need(nb.length == cnt, "RLNC 邻居数与位集不符 K=" + K + " blockId=" + blockId);
            for (int idx : nb) {
                need((raw[idx >>> 3] >>> (idx & 7) & 1) == 1,
                        "RLNC 邻居不在位集内 K=" + K + " blockId=" + blockId);
            }
            n++;
        }
        return n;
    }

    /** params.txt -> 选参算法 */
    public static int checkParams() {
        int n = 0;
        for (String line : lines("params.txt")) {
            String[] f = line.split("\\s+");
            long streamLen = Long.parseLong(f[0]);
            ParamPicker.Params p = ParamPicker.pick(streamLen);
            need(p.codec == Integer.parseInt(f[1]) && p.T == Integer.parseInt(f[2])
                            && p.K == Integer.parseInt(f[3]) && p.mAtV40 == Integer.parseInt(f[4])
                            && p.frames == Integer.parseInt(f[5]),
                    String.format("选参 streamLen=%d 期望 %s %s %s %s %s 实得 %d %d %d %d %d",
                            streamLen, f[1], f[2], f[3], f[4], f[5],
                            p.codec, p.T, p.K, p.mAtV40, p.frames));
            n++;
        }
        return n;
    }

    /** tiers.txt -> 档位表 */
    public static int checkTiers() {
        Map<Integer, List<QrCapacity.Tier>> cache = new HashMap<Integer, List<QrCapacity.Tier>>();
        Map<Integer, Integer> counts = new HashMap<Integer, Integer>();
        int n = 0;
        for (String line : lines("tiers.txt")) {
            String[] f = line.split("\\s+");
            int T = Integer.parseInt(f[0]);
            int idx = Integer.parseInt(f[1]);
            List<QrCapacity.Tier> tiers = cache.get(T);
            if (tiers == null) {
                tiers = QrCapacity.buildTiers(T);
                cache.put(T, tiers);
            }
            need(idx - 1 < tiers.size(), "档位数不足 T=" + T + " 档" + idx);
            QrCapacity.Tier t = tiers.get(idx - 1);
            need(t.version == Integer.parseInt(f[2]) && t.capacity == Integer.parseInt(f[3])
                            && t.m == Integer.parseInt(f[4]),
                    String.format("档位 T=%d 档%d 期望 V%s cap%s m%s 实得 V%d cap%d m%d",
                            T, idx, f[2], f[3], f[4], t.version, t.capacity, t.m));
            counts.put(T, idx);
            n++;
        }
        for (Map.Entry<Integer, Integer> e : counts.entrySet()) {
            need(cache.get(e.getKey()).size() == e.getValue(),
                    "档位数不一致 T=" + e.getKey() + " 期望 " + e.getValue()
                            + " 实得 " + cache.get(e.getKey()).size());
        }
        // 模块数公式
        need(QrCapacity.modulesOf(40) == 177, "V40 模块数应为 177");
        return n;
    }

    /** deflate_plain.bin / deflate_packed.bin -> inflate(packed) 必须逐字节等于 plain */
    public static int checkDeflate() {
        byte[] plain = bin("deflate_plain.bin");
        byte[] packed = bin("deflate_packed.bin");
        byte[] got = StreamCodec.inflateRaw(packed);
        need(Arrays.equals(got, plain),
                "inflate(deflate_packed.bin) 与 deflate_plain.bin 不一致");
        // 本端 deflate -> inflate 往返
        need(Arrays.equals(StreamCodec.inflateRaw(StreamCodec.deflateRaw(plain)), plain),
                "本端 raw deflate 往返失败");
        return plain.length;
    }

    /** fixture.bin + e2e.txt -> buildStream(不压缩) 必须等于 stream.bin，sessionId 必须一致 */
    public static int checkStreamAndSession() {
        Map<String, String> e2e = e2e();
        byte[] content = bin("fixture.bin");
        byte[] stream = bin("stream.bin");

        need(content.length == Integer.parseInt(e2e.get("contentLen")), "fixture 长度不符");
        need(hex(StreamCodec.sha256(content)).equals(e2e.get("contentSha256")), "fixture sha256 不符");

        StreamCodec.Built built = StreamCodec.buildStream(content, e2e.get("fileName"), false);
        need(Arrays.equals(built.stream, stream), "buildStream(不压缩) 与 stream.bin 不一致");
        need(built.stream.length == Integer.parseInt(e2e.get("streamLen")), "streamLen 不符");
        need(hex(StreamCodec.sha256(built.stream)).equals(e2e.get("streamSha256")), "streamSha256 不符");
        need(!built.meta.compressed, "强制不压缩时 flag 必须为 0");

        // 选参必须落在 e2e 的 rlnc 档
        ParamPicker.Params p = ParamPicker.pick(stream.length);
        need(p.codec == ParamPicker.CODEC_RLNC, "fixture 应落在解方程档");
        need(p.T == Integer.parseInt(e2e.get("rlnc.T")), "选参 T 与 e2e 不符");
        need(p.K == Integer.parseInt(e2e.get("rlnc.K")), "选参 K 与 e2e 不符");
        need(p.mAtV40 == Integer.parseInt(e2e.get("rlnc.m")), "选参 m 与 e2e 不符");

        byte[] digest = StreamCodec.sha256(content);
        for (String name : new String[]{"rlnc", "lt"}) {
            int codec = "rlnc".equals(name) ? ParamPicker.CODEC_RLNC : ParamPicker.CODEC_LT;
            int T = Integer.parseInt(e2e.get(name + ".T"));
            int K = Integer.parseInt(e2e.get(name + ".K"));
            int sid = SessionId.derive(digest, T, K, codec);
            need(SessionId.toHex(sid).equals(e2e.get(name + ".sessionId")),
                    name + " sessionId 期望 " + e2e.get(name + ".sessionId")
                            + " 实得 " + SessionId.toHex(sid));
        }
        return stream.length;
    }

    /** frames_rlnc.txt / frames_lt.txt -> encodeFrame 产出的整帧字节逐字节一致 */
    public static int checkFrames(String codecName) {
        Map<String, String> e2e = e2e();
        byte[] content = bin("fixture.bin");
        int codec = "rlnc".equals(codecName) ? ParamPicker.CODEC_RLNC : ParamPicker.CODEC_LT;
        int T = Integer.parseInt(e2e.get(codecName + ".T"));
        int K = Integer.parseInt(e2e.get(codecName + ".K"));
        int m = Integer.parseInt(e2e.get(codecName + ".m"));

        StreamCodec.Built built = StreamCodec.buildStream(content, e2e.get("fileName"), false);
        SendSession s = SendSession.create(built, content, codec, T, K, m);
        need(SessionId.toHex(s.sessionId).equals(e2e.get(codecName + ".sessionId")),
                codecName + " 会话 sessionId 不符");
        FrameEncoder enc = new FrameEncoder(s);

        int n = 0;
        for (String line : lines("frames_" + codecName + ".txt")) {
            int sp = line.indexOf(' ');
            int base = (int) Long.parseLong(line.substring(0, sp));
            String want = line.substring(sp + 1);
            String got = hex(enc.encodeFrame(base, m));
            need(got.equals(want), String.format(
                    "%s 帧 baseBlockId=%d 字节不一致%n期望 %s%n实得 %s", codecName, base,
                    brief(want), brief(got)));
            n++;
        }
        return n;
    }

    private static String brief(String h) {
        return h.length() <= 80 ? h : h.substring(0, 80) + "...(" + h.length() / 2 + "B)";
    }

    /** 自测：buildStream(压缩) -> parseStream 往返一致 */
    public static int checkStreamRoundTrip() {
        int n = 0;
        List<byte[]> samples = new ArrayList<byte[]>();
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 500; i++) {
            text.append("the quick brown fox jumps over the lazy dog\n");
        }
        samples.add(text.toString().getBytes());
        // 不可压缩的确定性随机数据
        byte[] rnd = new byte[30000];
        int st = Prng.mix32(2026);
        for (int i = 0; i < rnd.length; i += 4) {
            st = Prng.xorshift32(st);
            for (int j = 0; j < 4 && i + j < rnd.length; j++) {
                rnd[i + j] = (byte) (st >>> (24 - 8 * j));
            }
        }
        samples.add(rnd);
        samples.add(new byte[]{1});

        for (byte[] content : samples) {
            StreamCodec.Built b = StreamCodec.buildStream(content, "样本.bin");
            StreamCodec.Parsed p = StreamCodec.parseStream(b.stream);
            need(Arrays.equals(p.content, content), "往返内容不一致，长度 " + content.length);
            need("样本.bin".equals(p.meta.fileName), "往返文件名不一致");
            need(p.meta.originalSize == content.length, "往返 originalSize 不一致");
            need(Arrays.equals(p.meta.sha256, StreamCodec.sha256(content)), "往返 sha256 不一致");
            need(p.meta.compressed == b.meta.compressed, "往返 compressed flag 不一致");
            n++;
        }
        // 不可压缩数据必须自动关闭压缩
        StreamCodec.Built rb = StreamCodec.buildStream(rnd, "rnd.bin");
        need(!rb.meta.compressed, "不可压缩数据应自动关闭压缩并清 flag");
        need((rb.stream[3] & 1) == 0, "关闭压缩后 flags bit0 必须为 0");
        return n;
    }

    private static Map<String, String> e2e() {
        Map<String, String> m = new HashMap<String, String>();
        for (String line : lines("e2e.txt")) {
            int sp = line.indexOf(' ');
            m.put(line.substring(0, sp), line.substring(sp + 1).trim());
        }
        return m;
    }
}
