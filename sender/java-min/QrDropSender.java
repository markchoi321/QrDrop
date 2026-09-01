import com.google.zxing.EncodeHintType;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import com.google.zxing.qrcode.decoder.Mode;
import com.google.zxing.qrcode.encoder.ByteMatrix;
import com.google.zxing.qrcode.encoder.Encoder;
import com.google.zxing.qrcode.encoder.QRCode;

import javax.swing.*;
import java.awt.*;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.KeyEvent;
import java.awt.image.BufferedImage;
import java.io.*;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.zip.CRC32;
import java.util.zip.Deflater;

/**
 * QrDrop 发送端 · 单文件精简版（协议 v1，语义与 protocol/CONTRACT.md 逐位一致）。
 *
 * 全部实现都在这一个文件里：PRNG、Robust Soliton、两种编码方案、选参、档位、
 * 流层、会话、帧层、QR 渲染、播放界面。唯一外部依赖是 ZXing core 2.3.0。
 *
 *   javac -cp core-2.3.0.jar QrDropSender.java
 *   java  -cp core-2.3.0.jar:. QrDropSender                 # 图形界面
 *   java  -cp core-2.3.0.jar:. QrDropSender --dump in out 2 # 导出帧转储（校验用）
 *
 * 与完整版（sender/java）的差异：不做播放状态持久化，界面只保留必要旋钮。
 * 协议字节完全相同。
 */
public class QrDropSender {

    // ================================================================ 协议常量

    /** QR 版本 -> ECC=L 字节模式容量 */
    static final int[] CAP = {0,
            17, 32, 53, 78, 106, 134, 154, 192, 230, 271,
            321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
            929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732,
            1840, 1952, 2068, 2188, 2303, 2431, 2563, 2699, 2809, 2953};
    static final int HDR = 20;          // 帧头长度
    static final int CODEC_RLNC = 0, CODEC_LT = 1;

    // ================================================================ PRNG（契约 2）

    /** lowbias32 finalizer。右移必须是 >>>，乘法自然溢出即模 2^32 */
    static int mix32(int x) {
        x ^= x >>> 16; x *= 0x7FEB352D;
        x ^= x >>> 15; x *= 0x846CA68B;
        x ^= x >>> 16;
        return x;
    }

    static int xorshift32(int s) {
        s ^= s << 13; s ^= s >>> 17; s ^= s << 5;
        return s;
    }

    // ================================================================ 度分布（契约 4.1/4.2）

    /** 量化对数：把跨平台 ln 的 ulp 差异挡在 2^-16 网格外，否则两端会抽出不同度数 */
    static double lnq(double x) {
        return Math.floor(Math.log(x) * 65536.0 + 0.5) / 65536.0;
    }

    /** Robust Soliton 的量化 CDF，长度 K+1，下标从 1 起；末档兜底 2^32 */
    static long[] buildCdf(int K) {
        double c = 0.03, delta = 0.05;
        double[] p = new double[K + 2];
        p[1] = 1.0 / K;
        for (int d = 2; d <= K; d++) p[d] = 1.0 / ((double) d * (d - 1));
        double R = c * lnq(K / delta) * Math.sqrt(K);
        int kr = Math.max(1, (int) (K / R));
        for (int d = 1; d < Math.min(kr, K + 1); d++) p[d] += R / ((double) d * K);
        if (kr <= K) p[kr] += Math.max(0.0, R * lnq(R / delta) / K);
        double Z = 0.0;                      // 升序累加，顺序不可改
        for (int d = 1; d <= K; d++) Z += p[d];
        long[] cdf = new long[K + 1];
        double acc = 0.0;
        for (int d = 1; d <= K; d++) {
            acc += p[d] / Z;
            long q = (long) (acc * 4294967296.0);
            cdf[d] = q > 0xFFFFFFFFL ? 4294967296L : q;
        }
        cdf[K] = 4294967296L;
        return cdf;
    }

    // ================================================================ 编码块组成（契约 3.1/4.3）

    /** 剥洋葱（LT）：抽度数后拒绝采样抽互异索引 */
    static int[] neighborsLt(int blockId, int K, long[] cdf) {
        int state = xorshift32(mix32(blockId));
        long r = state & 0xFFFFFFFFL;
        int lo = 1, hi = K;
        while (lo < hi) {                    // 二分找最小的 d 使 cdf[d] > r
            int mid = (lo + hi) >>> 1;
            if (cdf[mid] <= r) lo = mid + 1; else hi = mid;
        }
        int d = Math.min(lo, K);
        boolean[] taken = new boolean[K];
        int[] out = new int[d];
        for (int n = 0; n < d; ) {
            state = xorshift32(state);
            int i = (int) (Integer.toUnsignedLong(state) % K);   // 无符号取模
            if (!taken[i]) { taken[i] = true; out[n++] = i; }
        }
        Arrays.sort(out);
        return out;
    }

    /**
     * 解方程（RLNC）：每个 32 位字独立经 mix32。
     * 严禁改用 xorshift32 连续输出拼接——那是 GF(2) 线性变换，秩永远停在 32。
     */
    static int[] neighborsRlnc(int blockId, int K) {
        int words = (K + 31) >>> 5;
        int[] bits = new int[words];
        int base = mix32(blockId);
        for (int i = 0; i < words; i++) bits[i] = mix32(base ^ (i * 0x9E3779B9));
        int rem = K & 31;
        if (rem != 0) bits[words - 1] &= (int) ((1L << rem) - 1);
        boolean zero = true;
        for (int i = 0; i < words; i++) if (bits[i] != 0) { zero = false; break; }
        if (zero) {                          // 全零兜底：全零块不携带信息
            int p = (int) (Integer.toUnsignedLong(blockId) % K);
            bits[p >>> 5] |= 1 << (p & 31);
        }
        int cnt = 0;
        for (int i = 0; i < words; i++) cnt += Integer.bitCount(bits[i]);
        int[] out = new int[cnt];
        for (int i = 0, n = 0; i < words; i++) {
            int w = bits[i];
            while (w != 0) {
                out[n++] = (i << 5) + Integer.numberOfTrailingZeros(w);
                w &= w - 1;
            }
        }
        return out;
    }

    // ================================================================ 选参与档位（契约 5/9）

    /** 返回 {codec, T, K}；并列取舍顺序固定为 帧数 -> T 最小 -> 解方程优先 */
    static int[] pickParams(long streamLen) {
        int bf = Integer.MAX_VALUE, bT = 0, bC = 0, bK = 0;
        for (int T = 16; T <= 500; T++) {
            int K = (int) Math.max(1L, (streamLen + T - 1) / T);
            int m = (2953 - HDR) / T;
            if (m < 1) continue;
            for (int codec = 0; codec <= 1; codec++) {
                if (codec == CODEC_RLNC && !(K <= 2720 && K <= 8 * T)) continue;
                if (codec == CODEC_LT && T < 293) continue;
                double eps = K <= 1 ? 0.0
                        : (codec == CODEC_RLNC ? 2.0 / K : 1.85 / Math.pow(K, 0.37));
                int need = (int) Math.ceil(K * (1.0 + eps));
                int frames = (need + m - 1) / m;
                if (bT == 0 || frames < bf || (frames == bf && T < bT)) {
                    bf = frames; bT = T; bC = codec; bK = K;
                }
            }
        }
        if (bT == 0) throw new IllegalStateException("选参失败: " + streamLen);
        return new int[]{bC, bT, bK};
    }

    /** 档位表，每项 {version, capacity, m}，m 升序，最多 10 档 */
    static List<int[]> buildTiers(int T) {
        int need = Math.max(512, HDR + T);
        Map<Integer, Integer> byM = new TreeMap<Integer, Integer>();
        for (int v = 1; v <= 40; v++) {
            if (CAP[v] < need) continue;
            int m = (CAP[v] - HDR) / T;
            if (m >= 1 && !byM.containsKey(m)) byM.put(m, v);   // 同一 m 只留最小版本
        }
        List<int[]> all = new ArrayList<int[]>();
        for (Map.Entry<Integer, Integer> e : byM.entrySet())
            all.add(new int[]{e.getValue(), CAP[e.getValue()], e.getKey()});
        if (all.size() <= 10) return all;
        // 超过 10 档按 m 的对数等比抽取，被挤掉的名额从尾部未选者回填
        int lo = all.get(0)[2], hi = all.get(all.size() - 1)[2];
        List<Integer> pick = new ArrayList<Integer>();
        for (int j = 0; j < 10; j++) {
            double target = lo * Math.pow((double) hi / lo, j / 9.0);
            int i = 0;
            while (i < all.size() && all.get(i)[2] < target) i++;
            if (i >= all.size()) i = all.size() - 1;
            while (pick.contains(i)) i++;
            if (i < all.size()) pick.add(i);
        }
        for (int i = all.size() - 1; pick.size() < 10 && i >= 0; i--)
            if (!pick.contains(i)) pick.add(i);
        java.util.Collections.sort(pick);
        List<int[]> out = new ArrayList<int[]>();
        for (int i : pick) out.add(all.get(i));
        return out;
    }

    // ================================================================ 会话（契约 6/7/8）

    String fileName;
    long originalSize;
    boolean compressed;
    int codec, T, K, sid, blocksNeeded;
    long streamLen;
    byte[][] src;                 // K 个源块，每块 T 字节，末块补零
    long[] cdf;                   // 仅剥洋葱用
    List<int[]> tiers;

    /** 建立会话：压缩 -> 选参 -> 推导 sessionId -> 切源块 */
    void openSession(byte[] content, String name) {
        byte[] sha = sha256(content);
        byte[] payload = deflateRaw(content);
        compressed = payload.length < content.length;   // 自适应：压不小就不压
        if (!compressed) payload = content;
        byte[] nameBytes = utf8(name);
        byte[] stream = new byte[54 + nameBytes.length + payload.length];
        stream[0] = 'V'; stream[1] = 'D'; stream[2] = 1;
        stream[3] = (byte) (compressed ? 1 : 0);
        putLong(stream, 4, content.length);
        putLong(stream, 12, payload.length);
        System.arraycopy(sha, 0, stream, 20, 32);
        stream[52] = (byte) (nameBytes.length >>> 8);
        stream[53] = (byte) nameBytes.length;
        System.arraycopy(nameBytes, 0, stream, 54, nameBytes.length);
        System.arraycopy(payload, 0, stream, 54 + nameBytes.length, payload.length);

        int[] p = pickParams(stream.length);
        codec = p[0]; T = p[1]; K = p[2];
        fileName = name;
        originalSize = content.length;
        streamLen = stream.length;
        src = new byte[K][];
        for (int i = 0; i < K; i++) {
            src[i] = new byte[T];
            int off = i * T, n = Math.min(T, Math.max(0, stream.length - off));
            if (n > 0) System.arraycopy(stream, off, src[i], 0, n);
        }
        cdf = codec == CODEC_LT ? buildCdf(K) : null;
        double eps = K <= 1 ? 0.0
                : (codec == CODEC_RLNC ? 2.0 / K : 1.85 / Math.pow(K, 0.37));
        blocksNeeded = (int) Math.ceil(K * (1.0 + eps));

        byte[] buf = new byte[38];                       // sessionId = SHA256(sha‖T‖K‖codec)[0..4)
        System.arraycopy(sha, 0, buf, 0, 32);
        buf[32] = (byte) (T >>> 8); buf[33] = (byte) T;
        buf[34] = (byte) (K >>> 16); buf[35] = (byte) (K >>> 8); buf[36] = (byte) K;
        buf[37] = (byte) codec;
        byte[] d = sha256(buf);
        sid = ((d[0] & 0xFF) << 24) | ((d[1] & 0xFF) << 16) | ((d[2] & 0xFF) << 8) | (d[3] & 0xFF);
        tiers = buildTiers(T);
    }

    /** 一帧 = 20 字节帧头 + m 个 T 字节编码块（块无头），第 i 块序号 = base + i */
    byte[] encodeFrame(int base, int m) {
        byte[] f = new byte[HDR + m * T];
        for (int i = 0; i < m; i++) {
            int bid = base + i;
            int[] nb = codec == CODEC_RLNC ? neighborsRlnc(bid, K) : neighborsLt(bid, K, cdf);
            int off = HDR + i * T;
            for (int k = 0; k < nb.length; k++) {
                byte[] s = src[nb[k]];
                for (int j = 0; j < T; j++) f[off + j] ^= s[j];
            }
        }
        f[0] = 0x56;
        f[1] = (byte) ((1 << 4) | ((compressed ? 1 : 0) << 3) | (codec << 2));
        putInt(f, 2, sid);
        f[6] = (byte) (K >>> 16); f[7] = (byte) (K >>> 8); f[8] = (byte) K;
        f[9] = (byte) (T >>> 8); f[10] = (byte) T;
        f[11] = (byte) m;
        putInt(f, 12, base);
        CRC32 crc = new CRC32();
        crc.update(f, HDR, f.length - HDR);              // CRC 覆盖偏移 20 到帧尾
        putInt(f, 16, (int) crc.getValue());
        return f;
    }

    // ================================================================ QR 渲染

    static final Map<EncodeHintType, Object> HINTS =
            new java.util.EnumMap<EncodeHintType, Object>(EncodeHintType.class);
    static { HINTS.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.L); }

    /** 一帧的模块位图（含 2 模块静区，1 模块 = 1 像素）与实际 QR 版本 */
    static final class Sym {
        final BufferedImage img; final int side, version;
        Sym(BufferedImage img, int side, int version) {
            this.img = img; this.side = side; this.version = version;
        }
    }

    /**
     * ZXing 2.3.0 没有 QR_VERSION hint，版本由载荷长度决定最小可容纳版本。
     * 档位的 m 本就由某个版本的容量反算，实际落点最低 V10，仍在 16 bit 字符计数分支内，
     * 接收端取字节模式段不受影响。不设 CHARACTER_SET hint（会插入 ECI 段导致错位）。
     */
    static Sym render(byte[] frame) throws Exception {
        QRCode qr = Encoder.encode(new String(frame, "ISO-8859-1"), ErrorCorrectionLevel.L, HINTS);
        if (qr.getMode() != Mode.BYTE) throw new IOException("非字节模式: " + qr.getMode());
        ByteMatrix m = qr.getMatrix();
        int n = m.getWidth(), side = n + 4;
        BufferedImage img = new BufferedImage(side, side, BufferedImage.TYPE_BYTE_BINARY);
        Graphics2D g = img.createGraphics();
        g.setColor(Color.WHITE); g.fillRect(0, 0, side, side);
        g.setColor(Color.BLACK);
        byte[][] a = m.getArray();
        for (int y = 0; y < n; y++) {                    // 逐行合并连续黑模块
            byte[] row = a[y];
            for (int x = 0; x < n; ) {
                if (row[x] != 1) { x++; continue; }
                int s = x;
                while (x < n && row[x] == 1) x++;
                g.fillRect(s + 2, y + 2, x - s, 1);
            }
        }
        g.dispose();
        return new Sym(img, side, qr.getVersion().getVersionNumber());
    }

    // ================================================================ 播放

    static final int[] FPS = {2, 5, 10, 15, 20, 25, 30};
    final ArrayBlockingQueue<Object[]> ring = new ArrayBlockingQueue<Object[]>(8);
    volatile Object[] plan;        // {epoch, m, startId}
    volatile int epoch;
    long nextBlockId, framesShown, starved;
    int tierIdx, intervalMs = 1000 / 15;
    boolean playing;
    Timer timer;

    final QrPanel panel = new QrPanel(), fullPanel = new QrPanel();
    final JComboBox<String> tierBox = new JComboBox<String>(), fpsBox = new JComboBox<String>();
    final JButton btnPlay = new JButton("开始播放");
    final JLabel info = new JLabel(" "), stat = new JLabel(" ");
    JWindow full;

    /** 白底、整数倍最近邻放大：非整数倍缩放会让模块边缘出现灰度过渡，损害识别率 */
    static final class QrPanel extends JPanel {
        BufferedImage img; int side;
        QrPanel() { setBackground(Color.WHITE); }
        void show(Sym s) { img = s.img; side = s.side; repaint(); }
        protected void paintComponent(Graphics g0) {
            super.paintComponent(g0);
            if (img == null) return;
            Graphics2D g = (Graphics2D) g0;
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                    RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
            int sc = Math.max(1, Math.min(getWidth(), getHeight()) / side), w = sc * side;
            g.drawImage(img, (getWidth() - w) / 2, (getHeight() - w) / 2, w, w, null);
        }
    }

    JFrame frame;

    /** 建界面。--dump 模式不调用它，因此无显示器环境也能跑 */
    void buildUI() {
        frame = new JFrame("QrDrop 发送端 · 精简版");
        frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
        frame.setLayout(new BorderLayout(6, 6));
        frame.add(controls(), BorderLayout.NORTH);
        panel.setPreferredSize(new Dimension(520, 520));
        frame.add(panel, BorderLayout.CENTER);
        JPanel south = new JPanel(new GridLayout(2, 1));
        south.add(info); south.add(stat);
        south.setBorder(BorderFactory.createEmptyBorder(2, 8, 6, 8));
        frame.add(south, BorderLayout.SOUTH);
        frame.pack();
        frame.setLocationRelativeTo(null);
        timer = new Timer(intervalMs, new ActionListener() {
            public void actionPerformed(ActionEvent e) { tick(); }
        });
        timer.setCoalesce(false);
        startRenderer();
        frame.setVisible(true);
    }

    JPanel controls() {
        JPanel row = new JPanel(new FlowLayout(FlowLayout.LEFT, 6, 6));
        row.add(button("选择文件", new Runnable() { public void run() { chooseFile(); } }));
        btnPlay.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                if (src == null) return;
                playing = !playing;
                if (playing) timer.start(); else timer.stop();
                btnPlay.setText(playing ? "暂停" : "开始播放");
            }
        });
        row.add(btnPlay);
        row.add(button("重置块序号", new Runnable() {
            public void run() { if (src != null) { nextBlockId = framesShown = 0; replan(); } }
        }));
        row.add(button("全屏", new Runnable() { public void run() { toggleFull(); } }));
        row.add(button("导出帧转储", new Runnable() { public void run() { exportDump(); } }));
        tierBox.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                int i = tierBox.getSelectedIndex();
                if (src != null && i >= 0 && i != tierIdx) { tierIdx = i; replan(); }
            }
        });
        for (int f : FPS) fpsBox.addItem(f + " fps（" + (1000 / f) + " ms）");
        fpsBox.setSelectedIndex(3);
        fpsBox.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                intervalMs = 1000 / FPS[fpsBox.getSelectedIndex()];
                timer.setDelay(intervalMs);
                timer.setInitialDelay(intervalMs);
            }
        });
        row.add(new JLabel("档位")); row.add(tierBox);
        row.add(new JLabel("帧率")); row.add(fpsBox);
        return row;
    }

    static JButton button(String text, final Runnable r) {
        JButton b = new JButton(text);
        b.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) { r.run(); }
        });
        return b;
    }

    void chooseFile() {
        JFileChooser fc = new JFileChooser();
        if (fc.showOpenDialog(frame) != JFileChooser.APPROVE_OPTION) return;
        File f = fc.getSelectedFile();
        try {
            playing = false; timer.stop(); btnPlay.setText("开始播放");
            openSession(readAll(f), f.getName());
            nextBlockId = framesShown = starved = 0;
            tierIdx = 0;                                  // 默认档：单帧容量最接近 2KB
            for (int i = 0, best = Integer.MAX_VALUE; i < tiers.size(); i++) {
                int d = Math.abs(tiers.get(i)[1] - 2048);
                if (d < best) { best = d; tierIdx = i; }
            }
            tierBox.removeAllItems();
            for (int i = 0; i < tiers.size(); i++)
                tierBox.addItem((i + 1) + " 档：每帧 " + tiers.get(i)[2] + " 块 / "
                        + (HDR + tiers.get(i)[2] * T) + " B");
            tierBox.setSelectedIndex(tierIdx);
            replan();
        } catch (Exception ex) {
            JOptionPane.showMessageDialog(frame, "会话创建失败: " + ex, "错误",
                    JOptionPane.ERROR_MESSAGE);
        }
    }

    /** 换档只改 m：T/K/codec/sessionId 不变，接收端已收块继续有效；旧档在途帧按 epoch 作废 */
    void replan() {
        epoch++;
        ring.clear();
        plan = new Object[]{Integer.valueOf(epoch), Integer.valueOf(tiers.get(tierIdx)[2]),
                Long.valueOf(nextBlockId)};
        try {                                             // 静止显示一帧供接收端取景合焦
            Sym s = render(encodeFrame((int) nextBlockId, tiers.get(tierIdx)[2]));
            panel.show(s);
            if (full != null) fullPanel.show(s);
            refresh(s.version);
        } catch (Exception e) {
            System.err.println("渲染失败: " + e);
        }
    }

    void tick() {
        Object[] it;
        while ((it = ring.poll()) != null && ((Integer) it[0]).intValue() != epoch) it = null;
        if (it == null) { starved++; return; }             // 缓冲空：保持当前帧，不推进游标
        Sym s = (Sym) it[2];
        panel.show(s);
        if (full != null) fullPanel.show(s);
        nextBlockId = (nextBlockId + ((Integer) it[1]).intValue()) & 0xFFFFFFFFL;
        framesShown++;
        refresh(s.version);
    }

    /** 后台预渲染：编码与光栅化都不落在切帧路径上 */
    void startRenderer() {
        Thread t = new Thread("qr-render") {
            public void run() {
                int local = -1;
                long produce = 0;
                while (true) {
                    Object[] p = plan;
                    if (p == null) { nap(50); continue; }
                    int ep = ((Integer) p[0]).intValue(), m = ((Integer) p[1]).intValue();
                    if (ep != local) { local = ep; produce = ((Long) p[2]).longValue(); }
                    Object[] item;
                    try {
                        item = new Object[]{Integer.valueOf(local), Integer.valueOf(m),
                                render(encodeFrame((int) produce, m))};
                    } catch (Exception e) {
                        System.err.println("渲染失败: " + e); nap(200); continue;
                    }
                    try {                                  // 队列满就等；等待中换了档就丢掉重来
                        while (!ring.offer(item, 50, TimeUnit.MILLISECONDS)) {
                            if (((Integer) plan[0]).intValue() != local) { item = null; break; }
                        }
                    } catch (InterruptedException e) { return; }
                    if (item != null) produce = (produce + m) & 0xFFFFFFFFL;
                }
            }
            void nap(int ms) { try { Thread.sleep(ms); } catch (InterruptedException ignored) { } }
        };
        t.setDaemon(true);
        t.setPriority(Thread.NORM_PRIORITY - 1);
        t.start();
    }

    void toggleFull() {
        if (full != null) { full.dispose(); full = null; return; }
        if (src == null) return;
        full = new JWindow(frame);
        full.getContentPane().add(fullPanel);
        full.setBounds(frame.getGraphicsConfiguration().getBounds());
        full.setVisible(true);
        fullPanel.registerKeyboardAction(new ActionListener() {
            public void actionPerformed(ActionEvent e) { toggleFull(); }
        }, KeyStroke.getKeyStroke(KeyEvent.VK_ESCAPE, 0), JPanel.WHEN_IN_FOCUSED_WINDOW);
        fullPanel.requestFocusInWindow();
        if (panel.img != null) { fullPanel.img = panel.img; fullPanel.side = panel.side; }
        fullPanel.repaint();
    }

    void exportDump() {
        if (src == null) return;
        JFileChooser fc = new JFileChooser();
        fc.setSelectedFile(new File(String.format("%08x", sid & 0xFFFFFFFFL) + ".vddump"));
        if (fc.showSaveDialog(frame) != JFileChooser.APPROVE_OPTION) return;
        try {
            int m = tiers.get(tierIdx)[2];
            int n = writeDump(fc.getSelectedFile(), m, 1);
            JOptionPane.showMessageDialog(frame, "已导出 " + n + " 帧");
        } catch (IOException e) {
            JOptionPane.showMessageDialog(frame, "导出失败: " + e, "错误", JOptionPane.ERROR_MESSAGE);
        }
    }

    void refresh(int version) {
        info.setText(fileName + "   原始 " + originalSize + " B，流层 " + streamLen + " B"
                + (compressed ? "（已压缩）" : "") + "   方案 "
                + (codec == CODEC_RLNC ? "解方程" : "剥洋葱")
                + "   T=" + T + "  K=" + K
                + "   会话 " + String.format("%08x", sid & 0xFFFFFFFFL));
        int m = tiers.get(tierIdx)[2];
        stat.setText(String.format("V%d  每帧 %d 块/%d B   已发 %d/%d 块（%.0f%%）   已播 %d 帧   缺帧 %d",
                version, m, HDR + m * T, nextBlockId, blocksNeeded,
                Math.min(100.0, nextBlockId * 100.0 / blocksNeeded), framesShown, starved));
    }

    // ================================================================ 工具

    /** 帧转储：连续的 [4 字节大端长度][帧字节]，可交给 protocol/crosscheck.py 校验 */
    int writeDump(File out, int m, int passes) throws IOException {
        int frames = ((blocksNeeded + m - 1) / m) * passes;
        DataOutputStream o = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(out)));
        try {
            for (int i = 0, base = 0; i < frames; i++, base += m) {
                byte[] f = encodeFrame(base, m);
                o.writeInt(f.length);
                o.write(f);
            }
        } finally { o.close(); }
        return frames;
    }

    static byte[] sha256(byte[] d) {
        try { return MessageDigest.getInstance("SHA-256").digest(d); }
        catch (Exception e) { throw new IllegalStateException(e); }
    }

    /** raw deflate（nowrap = true），无 zlib/gzip 容器 */
    static byte[] deflateRaw(byte[] data) {
        Deflater def = new Deflater(Deflater.BEST_COMPRESSION, true);
        try {
            def.setInput(data); def.finish();
            ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(64, data.length / 2));
            byte[] buf = new byte[8192];
            while (!def.finished()) {
                int n = def.deflate(buf);
                if (n <= 0) break;
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } finally { def.end(); }
    }

    static byte[] utf8(String s) {
        try { return s.getBytes("UTF-8"); } catch (Exception e) { throw new IllegalStateException(e); }
    }

    static void putInt(byte[] b, int p, int v) {
        b[p] = (byte) (v >>> 24); b[p + 1] = (byte) (v >>> 16);
        b[p + 2] = (byte) (v >>> 8); b[p + 3] = (byte) v;
    }

    static void putLong(byte[] b, int p, long v) {
        for (int i = 0; i < 8; i++) b[p + i] = (byte) (v >>> (56 - 8 * i));
    }

    static byte[] readAll(File f) throws IOException {
        byte[] buf = new byte[(int) f.length()];
        DataInputStream in = new DataInputStream(new FileInputStream(f));
        try { in.readFully(buf); } finally { in.close(); }
        return buf;
    }

    public static void main(String[] args) throws Exception {
        if (args.length >= 3 && "--dump".equals(args[0])) {   // 无界面导出，用于跨实现校验
            QrDropSender s = new QrDropSender();
            File in = new File(args[1]);
            s.openSession(readAll(in), in.getName());
            int m = s.tiers.get(s.tiers.size() / 2)[2];
            int passes = args.length > 3 ? Integer.parseInt(args[3]) : 1;
            int n = s.writeDump(new File(args[2]), m, passes);
            System.out.println("codec=" + s.codec + " T=" + s.T + " K=" + s.K + " m=" + m
                    + " frames=" + n + " sid=" + String.format("%08x", s.sid & 0xFFFFFFFFL));
            return;
        }
        SwingUtilities.invokeLater(new Runnable() {
            public void run() {
                try {
                    UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName());
                } catch (Exception ignored) { }
                new QrDropSender().buildUI();
            }
        });
    }
}
