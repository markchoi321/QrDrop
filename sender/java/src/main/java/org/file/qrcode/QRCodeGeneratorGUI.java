package org.file.qrcode;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.WriterException;
import com.google.zxing.client.j2se.MatrixToImageWriter;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;

import org.file.qrcode.protocol.FrameEncoder;
import org.file.qrcode.protocol.QrCapacity;
import org.file.qrcode.protocol.SendSession;
import org.file.qrcode.protocol.SessionId;

import javax.swing.*;
import java.awt.*;

import java.awt.event.KeyEvent;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * QrDrop 发送端界面（设计第 10 章）。
 *
 * 三阶段流程：① 选择文件（会话参数锁定）→ ② 对焦对齐（静止单帧）→ ③ 播放（无限帧流）。
 * 喷泉码下"第 N 片"的概念不存在，片段列表 / 上一个 / 下一个 / 片段筛选已全部移除。
 */
public class QRCodeGeneratorGUI extends JFrame {

    /** 窗口内二维码的目标边长（像素），实际按模块整数倍取整 */
    private static final int QR_TARGET_PX = 460;
    /** 预取窗口大小：当前帧之后保持这么多帧已生成 */
    private static final int PREFETCH_AHEAD = 24;
    /** LRU 缓存上限，单帧 ARGB 约 0.5 MB */
    private static final int CACHE_CAPACITY = 64;
    /** 间隔可调范围与推荐下限（设计 10.5） */
    private static final int INTERVAL_MIN = 10;
    private static final int INTERVAL_MAX = 1000;
    private static final int INTERVAL_WARN = 75;
    private static final int INTERVAL_DEFAULT = 100;
    /** 预计耗时估算所用的假定识别率（设计 10.6） */
    private static final double ASSUMED_RECOG_RATE = 0.9;
    /** 状态自动保存间隔（毫秒） */
    private static final long SAVE_INTERVAL_MS = 5000;

    private static final Font UI_FONT = new Font("微软雅黑", Font.PLAIN, 12);
    private static final Font SMALL_FONT = new Font("微软雅黑", Font.PLAIN, 11);
    private static final Font MONO_FONT = new Font("Monospaced", Font.PLAIN, 11);

    /** 三阶段 */
    private enum Stage { SELECT, ALIGN, PLAY }

    /** 队列中的一个文件：不可变会话 + 可变播放状态 */
    private static final class FileSession {
        final File file;
        final SendSession session;
        final FrameEncoder encoder;
        final PlaybackState state;

        FileSession(File file, SendSession session) {
            this.file = file;
            this.session = session;
            this.encoder = new FrameEncoder(session);
            this.state = PlaybackState.load(session.sessionId);
        }
    }

    /** 预取锚点：任一字段变化都让预取线程放弃当前批重新对齐 */
    private static final class Anchor {
        final int fileIndex;
        final int tier;
        final int version;
        final int m;
        final int targetPx;
        final boolean fit;
        final int base;
        final FrameEncoder encoder;

        Anchor(int fileIndex, int tier, int version, int m, int targetPx,
               boolean fit, int base, FrameEncoder encoder) {
            this.fileIndex = fileIndex;
            this.tier = tier;
            this.version = version;
            this.m = m;
            this.targetPx = targetPx;
            this.fit = fit;
            this.base = base;
            this.encoder = encoder;
        }
    }

    private final List<FileSession> queue = new ArrayList<FileSession>();
    private int currentIndex = 0;
    private Stage stage = Stage.SELECT;
    private boolean paused = false;
    private boolean fullscreen = false;

    /** 档位与间隔是全局设置（设计 10.9）：它们反映现场光学条件，切文件时条件没变 */
    private int tierIndex = 0;
    private int intervalMs = INTERVAL_DEFAULT;

    /**
     * LRU 图标缓存，键为 (fileIndex, tier, baseBlockId)。
     * 必须带档位——同一批块在不同档位下生成的是不同的二维码（设计 10.10）。
     */
    private final Map<Long, ImageIcon> iconCache = Collections.synchronizedMap(
            new LinkedHashMap<Long, ImageIcon>(CACHE_CAPACITY + 1, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<Long, ImageIcon> eldest) {
                    return size() > CACHE_CAPACITY;
                }
            }
    );

    /** 预取线程协调 */
    private final Object prefetchLock = new Object();
    private volatile Anchor anchor;
    private volatile boolean prefetchShutdown = false;

    private javax.swing.Timer timer;
    private long playedMillis = 0;
    private long playResumedAt = 0;
    private long lastSavedAt = 0;
    private Robot idleRobot;
    private long lastJiggleAt = 0;

    // 界面组件
    private JLabel qrLabel;
    private JPanel qrPanel;
    private JList<String> fileList;
    private DefaultListModel<String> fileListModel;
    private JButton btnStage;
    private JButton btnPause;
    private JButton btnFullscreen;
    private JButton btnResetCursor;
    private JButton btnTierDown;
    private JButton btnTierUp;
    private JLabel tierLabel;
    private JLabel tierDetailLabel;
    private JButton btnIntervalDown;
    private JButton btnIntervalUp;
    private JTextField intervalField;
    private JLabel intervalTipLabel;
    private JLabel[] paramLabels;
    private JLabel[] statLabels;
    private JButton btnDebugToggle;
    private JPanel debugPanel;
    private JLabel[] debugLabels;

    private JWindow fullWindow;
    private JLabel fullLabel;

    public QRCodeGeneratorGUI(List<FileSession> sessions) {
        this.queue.addAll(sessions);
        // 间隔与档位从首个会话的持久化状态恢复（两者是全局旋钮）；队列可以为空
        if (!queue.isEmpty()) {
            PlaybackState first = queue.get(0).state;
            if (first.intervalMs >= INTERVAL_MIN && first.intervalMs <= INTERVAL_MAX) {
                intervalMs = first.intervalMs;
            }
            if (first.tier >= 0 && first.tier < queue.get(0).session.tiers.size()) {
                tierIndex = first.tier;
            }
        }
        initUI();
        startPrefetchWorker();
        refreshAll();
        setupTimer();
    }

    // ------------------------------------------------------------ 会话访问

    /** 队列为空时返回 null，调用方须先判空 */
    private FileSession current() {
        if (queue.isEmpty() || currentIndex < 0 || currentIndex >= queue.size()) {
            return null;
        }
        return queue.get(currentIndex);
    }

    private boolean hasFile() {
        return current() != null;
    }

    /** 对焦阶段档位强制锁在档 1（设计 10.2） */
    private int effectiveTier() {
        if (stage == Stage.ALIGN) {
            return 0;
        }
        FileSession fs = current();
        return fs == null ? 0 : Math.min(tierIndex, fs.session.tiers.size() - 1);
    }

    private QrCapacity.Tier tierOf(FileSession fs, int idx) {
        List<QrCapacity.Tier> ts = fs.session.tiers;
        return ts.get(Math.max(0, Math.min(idx, ts.size() - 1)));
    }

    /** 队列为空时返回 null */
    private QrCapacity.Tier currentTier() {
        FileSession fs = current();
        return fs == null ? null : tierOf(fs, effectiveTier());
    }

    // ------------------------------------------------------------ 界面构建

    private void initUI() {
        setTitle("QrDrop 发送端");
        setDefaultCloseOperation(JFrame.DO_NOTHING_ON_CLOSE);
        setSize(1080, 760);
        setLocationRelativeTo(null);

        JPanel main = new JPanel(new BorderLayout(10, 10));
        main.setBorder(BorderFactory.createEmptyBorder(10, 10, 10, 10));

        // 左：二维码显示区，纯白背景无边框（设计 10.5）
        qrPanel = new JPanel(new GridBagLayout());
        qrPanel.setBackground(Color.WHITE);
        qrLabel = new JLabel("选择文件后点击「开始（对焦对齐）」", JLabel.CENTER);
        qrLabel.setFont(UI_FONT);
        qrLabel.setHorizontalAlignment(JLabel.CENTER);
        qrPanel.add(qrLabel);
        main.add(qrPanel, BorderLayout.CENTER);

        // 右：控制区
        JPanel side = new JPanel();
        side.setLayout(new BoxLayout(side, BoxLayout.Y_AXIS));
        side.add(buildQueuePanel());
        side.add(Box.createVerticalStrut(6));
        side.add(buildControlPanel());
        side.add(Box.createVerticalStrut(6));
        side.add(buildParamPanel());
        side.add(Box.createVerticalStrut(6));
        side.add(buildStatsPanel());
        side.add(Box.createVerticalStrut(6));
        side.add(buildDebugPanel());
        side.add(Box.createVerticalGlue());

        JScrollPane sideScroll = new JScrollPane(side,
                JScrollPane.VERTICAL_SCROLLBAR_AS_NEEDED,
                JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
        sideScroll.setBorder(null);
        sideScroll.setPreferredSize(new Dimension(380, 0));
        sideScroll.getVerticalScrollBar().setUnitIncrement(16);
        main.add(sideScroll, BorderLayout.EAST);

        add(main);

        addWindowListener(new java.awt.event.WindowAdapter() {
            @Override
            public void windowClosing(java.awt.event.WindowEvent e) {
                shutdown();
            }
        });
    }

    private JPanel buildQueuePanel() {
        JPanel p = new JPanel(new BorderLayout(4, 4));
        p.setBorder(BorderFactory.createTitledBorder("文件队列"));
        p.setMaximumSize(new Dimension(Integer.MAX_VALUE, 160));

        fileListModel = new DefaultListModel<String>();
        fileList = new JList<String>(fileListModel);
        fileList.setFont(SMALL_FONT);
        fileList.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        fileList.addListSelectionListener(e -> {
            if (!e.getValueIsAdjusting()) {
                int idx = fileList.getSelectedIndex();
                if (idx >= 0 && idx != currentIndex) {
                    switchFile(idx);
                }
            }
        });
        p.add(new JScrollPane(fileList), BorderLayout.CENTER);

        JButton btnAdd = new JButton("添加文件");
        btnAdd.setFont(SMALL_FONT);
        btnAdd.addActionListener(e -> chooseAndAddFiles());
        p.add(btnAdd, BorderLayout.SOUTH);
        return p;
    }

    private JPanel buildControlPanel() {
        JPanel p = new JPanel();
        p.setLayout(new BoxLayout(p, BoxLayout.Y_AXIS));
        p.setBorder(BorderFactory.createTitledBorder("播放控制"));
        p.setMaximumSize(new Dimension(Integer.MAX_VALUE, 250));

        JPanel row1 = new JPanel(new GridLayout(1, 2, 6, 0));
        btnStage = new JButton("开始（对焦对齐）");
        btnStage.setFont(UI_FONT);
        btnStage.addActionListener(e -> advanceStage());
        btnPause = new JButton("暂停");
        btnPause.setFont(UI_FONT);
        btnPause.addActionListener(e -> togglePause());
        row1.add(btnStage);
        row1.add(btnPause);

        JPanel row2 = new JPanel(new GridLayout(1, 2, 6, 0));
        btnFullscreen = new JButton("全屏播放");
        btnFullscreen.setFont(UI_FONT);
        btnFullscreen.addActionListener(e -> enterFullscreen());
        btnResetCursor = new JButton("重置块序号");
        btnResetCursor.setFont(UI_FONT);
        btnResetCursor.addActionListener(e -> resetCursor());
        row2.add(btnFullscreen);
        row2.add(btnResetCursor);

        // 档位：逐档调整，不提供跳档（设计 10.4）
        JPanel tierRow = new JPanel(new BorderLayout(4, 0));
        btnTierDown = new JButton("◄");
        btnTierDown.setFont(UI_FONT);
        btnTierDown.addActionListener(e -> changeTier(-1));
        btnTierUp = new JButton("►");
        btnTierUp.setFont(UI_FONT);
        btnTierUp.addActionListener(e -> changeTier(1));
        tierLabel = new JLabel("档位", JLabel.CENTER);
        tierLabel.setFont(UI_FONT);
        tierRow.add(btnTierDown, BorderLayout.WEST);
        tierRow.add(tierLabel, BorderLayout.CENTER);
        tierRow.add(btnTierUp, BorderLayout.EAST);

        tierDetailLabel = new JLabel(" ", JLabel.CENTER);
        tierDetailLabel.setFont(SMALL_FONT);

        // 间隔
        JPanel intervalRow = new JPanel(new BorderLayout(4, 0));
        btnIntervalDown = new JButton("◄");
        btnIntervalDown.setFont(UI_FONT);
        btnIntervalDown.addActionListener(e -> changeInterval(-5));
        btnIntervalUp = new JButton("►");
        btnIntervalUp.setFont(UI_FONT);
        btnIntervalUp.addActionListener(e -> changeInterval(5));
        intervalField = new JTextField(String.valueOf(intervalMs));
        intervalField.setFont(UI_FONT);
        intervalField.setHorizontalAlignment(JTextField.CENTER);
        intervalField.addActionListener(e -> applyIntervalText());
        intervalRow.add(btnIntervalDown, BorderLayout.WEST);
        intervalRow.add(intervalField, BorderLayout.CENTER);
        intervalRow.add(btnIntervalUp, BorderLayout.EAST);

        intervalTipLabel = new JLabel(" ", JLabel.CENTER);
        intervalTipLabel.setFont(SMALL_FONT);

        p.add(row1);
        p.add(Box.createVerticalStrut(4));
        p.add(row2);
        p.add(Box.createVerticalStrut(8));
        p.add(labeled("档位（逐档调整）"));
        p.add(tierRow);
        p.add(tierDetailLabel);
        p.add(Box.createVerticalStrut(6));
        p.add(labeled("间隔（毫秒，推荐 75-100）"));
        p.add(intervalRow);
        p.add(intervalTipLabel);
        return p;
    }

    private JLabel labeled(String text) {
        JLabel l = new JLabel(text);
        l.setFont(SMALL_FONT);
        l.setAlignmentX(Component.LEFT_ALIGNMENT);
        return l;
    }

    /** 会话参数区：只读、不含任何可交互控件（设计 10.3） */
    private JPanel buildParamPanel() {
        JPanel p = new JPanel(new GridLayout(6, 1));
        p.setBorder(BorderFactory.createTitledBorder("会话参数（锁定，改了就换会话）"));
        p.setMaximumSize(new Dimension(Integer.MAX_VALUE, 150));
        paramLabels = new JLabel[6];
        for (int i = 0; i < paramLabels.length; i++) {
            paramLabels[i] = new JLabel(" ");
            paramLabels[i].setFont(SMALL_FONT);
            p.add(paramLabels[i]);
        }
        return p;
    }

    /** 播放统计区：只读观测值，不做成进度条形态（设计 10.6） */
    private JPanel buildStatsPanel() {
        JPanel p = new JPanel(new GridLayout(6, 1));
        p.setBorder(BorderFactory.createTitledBorder("播放统计"));
        p.setMaximumSize(new Dimension(Integer.MAX_VALUE, 150));
        statLabels = new JLabel[6];
        for (int i = 0; i < statLabels.length; i++) {
            statLabels[i] = new JLabel(" ");
            statLabels[i].setFont(SMALL_FONT);
            p.add(statLabels[i]);
        }
        // 常驻说明：发送端无从得知接收端进度（设计 3.5 / 10.6）
        statLabels[5].setText("注意: 这不是接收端的接收进度");
        statLabels[5].setForeground(new Color(200, 90, 0));
        return p;
    }

    private JPanel buildDebugPanel() {
        JPanel wrap = new JPanel(new BorderLayout());
        wrap.setBorder(BorderFactory.createTitledBorder("调试"));
        wrap.setMaximumSize(new Dimension(Integer.MAX_VALUE, 160));

        btnDebugToggle = new JButton("展开调试面板");
        btnDebugToggle.setFont(SMALL_FONT);
        btnDebugToggle.addActionListener(e -> {
            debugPanel.setVisible(!debugPanel.isVisible());
            btnDebugToggle.setText(debugPanel.isVisible() ? "折叠调试面板" : "展开调试面板");
            refreshStats();
            revalidate();
        });
        wrap.add(btnDebugToggle, BorderLayout.NORTH);

        debugPanel = new JPanel(new GridLayout(4, 1));
        debugLabels = new JLabel[4];
        for (int i = 0; i < debugLabels.length; i++) {
            debugLabels[i] = new JLabel(" ");
            debugLabels[i].setFont(MONO_FONT);
            debugPanel.add(debugLabels[i]);
        }
        debugPanel.setVisible(false);
        wrap.add(debugPanel, BorderLayout.CENTER);
        return wrap;
    }

    // ------------------------------------------------------------ 阶段流转

    private void advanceStage() {
        if (!hasFile()) {
            return;
        }
        if (stage == Stage.SELECT) {
            stage = Stage.ALIGN;
            // 对焦阶段：静止显示单帧，档位锁档 1，间隔置灰
            clearCacheAndRealign();
            showCurrentFrame(false);
        } else if (stage == Stage.ALIGN) {
            stage = Stage.PLAY;
            paused = false;
            playResumedAt = System.currentTimeMillis();
            clearCacheAndRealign();
        }
        refreshAll();
    }

    private void togglePause() {
        if (stage != Stage.PLAY) {
            return;
        }
        paused = !paused;
        if (paused) {
            playedMillis += System.currentTimeMillis() - playResumedAt;
        } else {
            playResumedAt = System.currentTimeMillis();
        }
        refreshControls();
    }

    private void resetCursor() {
        FileSession fs = current();
        if (fs == null) return;
        fs.state.resetCursor();
        fs.state.save();
        clearCacheAndRealign();
        showCurrentFrame(false);
        refreshStats();
    }

    private void switchFile(int idx) {
        saveCurrentState();
        currentIndex = idx;
        FileSession fs = current();
        if (fs == null) { refreshAll(); return; }
        // 全局档位对新会话可能越界，夹紧
        tierIndex = Math.min(tierIndex, fs.session.tiers.size() - 1);
        clearCacheAndRealign();
        showCurrentFrame(false);
        refreshAll();
    }

    private void changeTier(int delta) {
        if (stage == Stage.ALIGN) {
            return;
        }
        FileSession cur = current();
        if (cur == null) return;
        int max = cur.session.tiers.size() - 1;
        int next = Math.max(0, Math.min(tierIndex + delta, max));
        if (next == tierIndex) {
            return;
        }
        tierIndex = next;
        // 换档只改 m：T / K / codec / sessionId 全部不变，接收端已收块继续有效。
        // 游标不重置，但旧档缓存全部作废（设计 10.10）
        clearCacheAndRealign();
        showCurrentFrame(false);
        refreshAll();
    }

    private void changeInterval(int delta) {
        setInterval(intervalMs + delta);
    }

    private void applyIntervalText() {
        try {
            setInterval(Integer.parseInt(intervalField.getText().trim()));
        } catch (NumberFormatException e) {
            intervalTipLabel.setText("请输入 " + INTERVAL_MIN + "-" + INTERVAL_MAX + " 之间的整数");
            intervalTipLabel.setForeground(Color.RED);
        }
    }

    private void setInterval(int ms) {
        if (ms < INTERVAL_MIN || ms > INTERVAL_MAX) {
            intervalTipLabel.setText("间隔须在 " + INTERVAL_MIN + "-" + INTERVAL_MAX + " 毫秒之间");
            intervalTipLabel.setForeground(Color.RED);
            return;
        }
        intervalMs = ms;
        intervalField.setText(String.valueOf(ms));
        if (timer != null) {
            timer.setInitialDelay(ms);
            timer.setDelay(ms);
            timer.restart();
        }
        // 低于推荐下限只警告不拒绝：阈值来自经验，应允许用户越过并自行观察
        if (ms < INTERVAL_WARN) {
            intervalTipLabel.setText("低于推荐下限 " + INTERVAL_WARN + " ms，识别率可能明显下降");
            intervalTipLabel.setForeground(new Color(200, 90, 0));
        } else {
            intervalTipLabel.setText("当前 " + ms + " ms");
            intervalTipLabel.setForeground(new Color(60, 120, 60));
        }
        FileSession curFs = current();
        if (curFs != null) curFs.state.intervalMs = ms;
    }

    // ------------------------------------------------------------ 播放循环

    private void setupTimer() {
        // 单次定时器 + 自重启，严格保证两次切换之间至少 interval 毫秒
        timer = new javax.swing.Timer(intervalMs, e -> {
            try {
                tick();
            } catch (Exception ex) {
                ex.printStackTrace();
            }
            timer.restart();
        });
        timer.setRepeats(false);
        timer.start();
    }

    private void tick() {
        if (stage != Stage.PLAY || paused) {
            return;
        }
        FileSession fs = current();
        if (fs == null) return;
        int m = currentTier().m;
        // 先真正显示，再推进游标（设计 10.8）
        showCurrentFrame(false);
        fs.state.advanceAfterShown(m);
        refreshStats();
        suppressScreenSaver();
        long now = System.currentTimeMillis();
        if (now - lastSavedAt > SAVE_INTERVAL_MS) {
            lastSavedAt = now;
            saveCurrentState();
        }
    }

    /** 渲染当前游标处的帧并上屏；needFrameBytes 为 true 时额外返回帧字节供调试面板使用 */
    private byte[] showCurrentFrame(boolean needFrameBytes) {
        FileSession fs = current();
        if (fs == null) {
            qrLabel.setIcon(null);
            qrLabel.setText("请先添加文件");
            return null;
        }
        qrLabel.setText(null);
        int tier = effectiveTier();
        QrCapacity.Tier t = tierOf(fs, tier);
        int base = fs.state.baseBlockId();
        long key = cacheKey(currentIndex, tier, base);
        ImageIcon icon = iconCache.get(key);
        byte[] frame = null;
        if (icon == null) {
            frame = fs.encoder.encodeFrame(base, t.m);
            try {
                icon = new ImageIcon(generateQRCode(frame, t.version, targetPx(), fullscreen));
            } catch (WriterException ex) {
                ex.printStackTrace();
                return null;
            }
            iconCache.put(key, icon);
        } else if (needFrameBytes) {
            // 缓存只存图片；调试面板需要原始字节时重新编码一次，代价仅在展开调试时付出
            frame = fs.encoder.encodeFrame(base, t.m);
        }
        if (fullscreen && fullLabel != null) {
            fullLabel.setIcon(icon);
        } else {
            qrLabel.setText(null);
            qrLabel.setIcon(icon);
        }
        // 记录播放状态里的档位信息，供持久化
        fs.state.tier = tier;
        fs.state.qrVersion = t.version;
        fs.state.m = t.m;
        fs.state.intervalMs = intervalMs;
        notifyPrefetch();
        return frame;
    }

    private int targetPx() {
        if (fullscreen) {
            Rectangle b = GraphicsEnvironment.getLocalGraphicsEnvironment()
                    .getDefaultScreenDevice().getDefaultConfiguration().getBounds();
            return Math.min(b.width, b.height);
        }
        return QR_TARGET_PX;
    }

    private static long cacheKey(int fileIndex, int tier, int baseBlockId) {
        return ((long) fileIndex << 36) | ((long) tier << 32) | (baseBlockId & 0xFFFFFFFFL);
    }

    // ------------------------------------------------------------ 预取线程

    private void startPrefetchWorker() {
        Thread th = new Thread(new Runnable() {
            @Override
            public void run() {
                while (!prefetchShutdown) {
                    Anchor a = anchor;
                    if (a != null) {
                        // 帧序列无限，窗口按 blockId 单调推进，不取模（设计 10.10）
                        for (int off = 1; off <= PREFETCH_AHEAD && !prefetchShutdown; off++) {
                            if (anchor != a) {
                                break;
                            }
                            int base = (int) ((a.base & 0xFFFFFFFFL) + (long) off * a.m);
                            long key = cacheKey(a.fileIndex, a.tier, base);
                            if (iconCache.containsKey(key)) {
                                continue;
                            }
                            try {
                                byte[] frame = a.encoder.encodeFrame(base, a.m);
                                BufferedImage img = generateQRCode(frame, a.version, a.targetPx, a.fit);
                                // 生成期间可能已经换档：必须在锁内二次确认锚点未变，
                                // 否则这张旧档图片会写在清空之后，白占缓存槽位
                                synchronized (prefetchLock) {
                                    if (anchor != a) {
                                        break;
                                    }
                                    iconCache.put(key, new ImageIcon(img));
                                }
                            } catch (Exception ex) {
                                ex.printStackTrace();
                            }
                        }
                    }
                    synchronized (prefetchLock) {
                        if (anchor == a && !prefetchShutdown) {
                            try {
                                prefetchLock.wait(500);
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                                return;
                            }
                        }
                    }
                }
            }
        }, "qr-prefetch");
        th.setDaemon(true);
        th.start();
    }

    /** 队列为空时返回 null，预取线程据此空转 */
    private Anchor buildAnchor() {
        FileSession fs = current();
        if (fs == null) return null;
        int tier = effectiveTier();
        QrCapacity.Tier t = tierOf(fs, tier);
        return new Anchor(currentIndex, tier, t.version, t.m, targetPx(),
                fullscreen, fs.state.baseBlockId(), fs.encoder);
    }

    private void notifyPrefetch() {
        Anchor a = buildAnchor();
        synchronized (prefetchLock) {
            anchor = a;
            prefetchLock.notifyAll();
        }
    }

    /** 换档 / 切文件 / 进出全屏：旧图全部作废，清空缓存并重新对齐预取窗口 */
    private void clearCacheAndRealign() {
        Anchor a = buildAnchor();
        // 先换锚点再清缓存，且都在锁内：预取线程 put 前会二次确认锚点，
        // 这样"清空之后又被写入旧档图片"的竞态被彻底排除
        synchronized (prefetchLock) {
            anchor = a;
            iconCache.clear();
            prefetchLock.notifyAll();
        }
    }

    // ------------------------------------------------------------ 二维码生成

    /**
     * 生成二维码图片。
     *
     * 入参是原始字节：交给 ZXing 前用 ISO-8859-1 逐字节映射成 String，走 byte 模式；
     * 绝不设置 CHARACTER_SET hint——设置它会插入 ECI 段，令单帧上限从 2953 降到 2952。
     * 版本由档位强制指定。
     *
     * @param fit true 时向下取整（保证不超出屏幕，全屏用），false 时向上取整
     */
    private BufferedImage generateQRCode(byte[] data, int version, int targetPx, boolean fit)
            throws WriterException {
        Map<EncodeHintType, Object> hints = new HashMap<EncodeHintType, Object>();
        hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.L);
        hints.put(EncodeHintType.MARGIN, 2);
        hints.put(EncodeHintType.QR_VERSION, version);

        String content = new String(data, Charset.forName("ISO-8859-1"));
        QRCodeWriter writer = new QRCodeWriter();

        // 第一次编码取精确模块数（含 quiet zone）
        BitMatrix probe = writer.encode(content, BarcodeFormat.QR_CODE, 0, 0, hints);
        int modules = probe.getWidth();

        // 模块的整数倍像素：非整数倍缩放会让模块边缘出现灰度过渡，直接损害识别率
        int moduleSize = fit ? targetPx / modules : (targetPx + modules - 1) / modules;
        if (moduleSize < 1) {
            moduleSize = 1;
        }
        int exact = moduleSize * modules;

        BitMatrix matrix = writer.encode(content, BarcodeFormat.QR_CODE, exact, exact, hints);
        return MatrixToImageWriter.toBufferedImage(matrix);
    }

    // ------------------------------------------------------------ 全屏

    private void enterFullscreen() {
        if (fullscreen) {
            return;
        }
        fullscreen = true;
        fullWindow = new JWindow(this);
        fullWindow.getContentPane().setBackground(Color.WHITE);
        fullWindow.getContentPane().setLayout(new GridBagLayout());
        fullLabel = new JLabel();
        fullLabel.setHorizontalAlignment(JLabel.CENTER);
        fullWindow.getContentPane().add(fullLabel);
        fullWindow.setBackground(Color.WHITE);

        GraphicsDevice dev = GraphicsEnvironment.getLocalGraphicsEnvironment()
                .getDefaultScreenDevice();
        fullWindow.setBounds(dev.getDefaultConfiguration().getBounds());
        // 无边框、纯白、无过渡动画；ESC 或双击退出
        JRootPane root = fullWindow.getRootPane();
        root.getInputMap(JComponent.WHEN_IN_FOCUSED_WINDOW)
                .put(KeyStroke.getKeyStroke(KeyEvent.VK_ESCAPE, 0), "exitFull");
        root.getActionMap().put("exitFull", new AbstractAction() {
            @Override
            public void actionPerformed(java.awt.event.ActionEvent e) {
                exitFullscreen();
            }
        });
        fullWindow.getContentPane().addMouseListener(new java.awt.event.MouseAdapter() {
            @Override
            public void mouseClicked(java.awt.event.MouseEvent e) {
                if (e.getClickCount() == 2) {
                    exitFullscreen();
                }
            }
        });
        fullWindow.setVisible(true);
        fullWindow.requestFocus();
        clearCacheAndRealign();
        showCurrentFrame(false);
        refreshControls();
    }

    private void exitFullscreen() {
        if (!fullscreen) {
            return;
        }
        fullscreen = false;
        if (fullWindow != null) {
            fullWindow.setVisible(false);
            fullWindow.dispose();
            fullWindow = null;
            fullLabel = null;
        }
        clearCacheAndRealign();
        showCurrentFrame(false);
        refreshControls();
        toFront();
    }

    /** 播放中周期性抑制屏保：16 MB 文件默认档需连续播放一小时以上（设计 10.5） */
    private void suppressScreenSaver() {
        long now = System.currentTimeMillis();
        if (now - lastJiggleAt < 50000) {
            return;
        }
        lastJiggleAt = now;
        try {
            if (idleRobot == null) {
                idleRobot = new Robot();
            }
            PointerInfo pi = MouseInfo.getPointerInfo();
            if (pi != null) {
                Point p = pi.getLocation();
                idleRobot.mouseMove(p.x + 1, p.y);
                idleRobot.mouseMove(p.x, p.y);
            }
        } catch (Exception ignored) {
            // 无 Robot 权限时放弃抑制，不影响播放
        }
    }

    // ------------------------------------------------------------ 界面刷新

    private void refreshAll() {
        refreshQueue();
        refreshControls();
        refreshParams();
        refreshStats();
    }

    private void refreshQueue() {
        int sel = currentIndex;
        fileListModel.clear();
        for (int i = 0; i < queue.size(); i++) {
            FileSession fs = queue.get(i);
            String status;
            if (i == currentIndex && stage == Stage.PLAY && !paused) {
                status = "播放中";
            } else if (fs.state.nextBlockId == 0) {
                status = "未开始";
            } else {
                double rounds = (double) fs.state.nextBlockId / fs.session.blocksNeeded;
                status = rounds >= 1.0 ? String.format("已播满 %.2f 轮", rounds) : "进行中";
            }
            fileListModel.addElement(String.format("%s  %s  %s",
                    fs.file.getName(), humanSize(fs.file.length()), status));
        }
        fileList.setSelectedIndex(sel);
    }

    private void refreshControls() {
        boolean align = stage == Stage.ALIGN;
        boolean play = stage == Stage.PLAY;
        btnStage.setText(stage == Stage.SELECT ? "开始（对焦对齐）"
                : align ? "播放" : "播放中");
        btnStage.setEnabled(!play && hasFile());
        btnPause.setEnabled(play);
        btnPause.setText(paused ? "继续" : "暂停");
        btnFullscreen.setEnabled(!fullscreen && stage != Stage.SELECT);
        btnResetCursor.setEnabled(stage != Stage.SELECT);
        // 对焦阶段档位锁档 1、间隔置灰（设计 10.2）
        btnTierDown.setEnabled(play);
        btnTierUp.setEnabled(play);
        boolean intervalEditable = !align;
        intervalField.setEnabled(intervalEditable);
        btnIntervalDown.setEnabled(intervalEditable);
        btnIntervalUp.setEnabled(intervalEditable);

        FileSession fs = current();
        if (fs == null) {
            tierLabel.setText("档 - / -");
            tierDetailLabel.setText("请先添加文件");
            return;
        }
        int tier = effectiveTier();
        QrCapacity.Tier t = tierOf(fs, tier);
        tierLabel.setText(String.format("档 %d / %d", tier + 1, fs.session.tiers.size()));
        tierDetailLabel.setText(String.format("V%d · %dB · 每帧 %d 块 · %d×",
                t.version, t.capacity, t.m, t.m));
        if (align) {
            tierDetailLabel.setText(tierDetailLabel.getText() + "（对焦阶段锁定）");
        }
    }

    private void refreshParams() {
        FileSession cur = current();
        if (cur == null) {
            paramLabels[0].setText("尚未选择文件");
            for (int i = 1; i < paramLabels.length; i++) paramLabels[i].setText(" ");
            return;
        }
        SendSession s = cur.session;
        paramLabels[0].setText(String.format("文件  %s（%s）",
                s.meta.fileName, humanSize(s.meta.originalSize)));
        paramLabels[1].setText(String.format("块大小 T = %d B    总块数 K = %d", s.T, s.K));
        paramLabels[2].setText(String.format("编码方案  %s    压缩  %s",
                s.codecName(), s.meta.compressed ? "是" : "否"));
        paramLabels[3].setText(String.format("开销 ε = %.2f%%    流长度 %s",
                s.eps * 100, humanSize(s.streamLen)));
        paramLabels[4].setText("sessionId  " + SessionId.toHex(s.sessionId));
        paramLabels[5].setText("以上参数在会话内不可更改");
    }

    private void refreshStats() {
        FileSession fs = current();
        if (fs == null) {
            for (JLabel l : statLabels) l.setText(" ");
            return;
        }
        SendSession s = fs.session;
        PlaybackState st = fs.state;
        long sent = st.nextBlockId;
        int need = s.blocksNeeded;
        double rounds = (double) sent / need;
        int m = currentTier().m;

        statLabels[0].setText(String.format("已发编码块  %d / 预计所需 %d", sent, need));
        statLabels[1].setText(String.format("已播轮次  %.2f 轮%s", rounds,
                rounds >= 1.0 ? "（接收端若未完成请继续）" : ""));
        statLabels[2].setText(String.format("已播帧数  %d / 预计所需 %d",
                st.framesShown, (need + m - 1) / m));
        long remain = Math.max(0, need - sent);
        double etaSec = remain / (double) m * intervalMs / 1000.0 / ASSUMED_RECOG_RATE;
        // 已发编码块与已播帧数随 PlaybackState 持久化、跨重启累计，而计时器每次启动归零，
        // 两者并列会显得自相矛盾，故明确标注计时的范围
        statLabels[3].setText(String.format("本次已用时  %s", formatDuration(elapsedMillis())));
        statLabels[4].setText(String.format("预计剩余  约 %s（按识别率 %.0f%% 估计）",
                formatDuration((long) (etaSec * 1000)), ASSUMED_RECOG_RATE * 100));

        if (debugPanel.isVisible()) {
            refreshDebug();
        }
        refreshQueueStatusOnly();
    }

    private void refreshQueueStatusOnly() {
        if (fileListModel.size() != queue.size()) {
            refreshQueue();
        }
    }

    private void refreshDebug() {
        FileSession fs = current();
        if (fs == null) {
            for (JLabel l : debugLabels) l.setText(" ");
            return;
        }
        QrCapacity.Tier t = currentTier();
        int base = fs.state.baseBlockId();
        byte[] frame = fs.encoder.encodeFrame(base, t.m);
        debugLabels[0].setText("baseBlockId = " + (base & 0xFFFFFFFFL));
        debugLabels[1].setText("frameLen = " + frame.length + " B (20 + " + t.m + "x" + fs.session.T + ")");
        debugLabels[2].setText("head = " + hex(frame, 0, FrameEncoder.HEADER_LEN));
        debugLabels[3].setText(String.format("载荷率 = %.1f%%  (%d/%d)",
                t.payloadRate(fs.session.T) * 100, t.m * fs.session.T, t.capacity));
    }

    private long elapsedMillis() {
        long v = playedMillis;
        if (stage == Stage.PLAY && !paused && playResumedAt > 0) {
            v += System.currentTimeMillis() - playResumedAt;
        }
        return v;
    }

    // ------------------------------------------------------------ 工具

    private static String hex(byte[] b, int off, int len) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < len; i++) {
            sb.append(String.format("%02x", b[off + i]));
        }
        return sb.toString();
    }

    private static String humanSize(long n) {
        if (n < 1024) {
            return n + " B";
        }
        if (n < 1024 * 1024) {
            return String.format("%.1f KB", n / 1024.0);
        }
        return String.format("%.2f MB", n / (1024.0 * 1024));
    }

    private static String formatDuration(long ms) {
        long s = ms / 1000;
        if (s < 60) {
            return s + " s";
        }
        if (s < 3600) {
            return String.format("%d 分 %02d 秒", s / 60, s % 60);
        }
        return String.format("%d 时 %02d 分", s / 3600, (s % 3600) / 60);
    }

    private void saveCurrentState() {
        FileSession fsSave = current();
        if (fsSave == null) return;
        fsSave.state.intervalMs = intervalMs;
        fsSave.state.save();
    }

    private void shutdown() {
        prefetchShutdown = true;
        synchronized (prefetchLock) {
            prefetchLock.notifyAll();
        }
        for (FileSession fs : queue) {
            fs.state.intervalMs = intervalMs;
            fs.state.save();
        }
        dispose();
        System.exit(0);
    }

    private void chooseAndAddFiles() {
        JFileChooser fc = new JFileChooser();
        fc.setMultiSelectionEnabled(true);
        if (fc.showOpenDialog(this) != JFileChooser.APPROVE_OPTION) {
            return;
        }
        for (File f : fc.getSelectedFiles()) {
            try {
                queue.add(buildSession(f));
            } catch (Exception ex) {
                JOptionPane.showMessageDialog(this, "读取失败: " + f.getName() + "\n" + ex.getMessage());
            }
        }
        refreshAll();
    }

    // ------------------------------------------------------------ 入口

    private static FileSession buildSession(File file) throws IOException {
        byte[] content = Files.readAllBytes(file.toPath());
        SendSession s = SendSession.create(content, file.getName());
        return new FileSession(file, s);
    }

    public static void main(String[] args) {
        final List<File> files = new ArrayList<File>();
        for (String a : args) {
            File f = new File(a);
            if (!f.isFile()) {
                System.err.println("文件不存在: " + a);
                return;
            }
            files.add(f);
        }
        final List<FileSession> sessions = new ArrayList<FileSession>();
        try {
            for (File f : files) {
                FileSession fs = buildSession(f);
                sessions.add(fs);
                System.out.printf("%s: T=%d K=%d %s eps=%.2f%% sessionId=%s 档位%d档%n",
                        f.getName(), fs.session.T, fs.session.K, fs.session.codecName(),
                        fs.session.eps * 100, SessionId.toHex(fs.session.sessionId),
                        fs.session.tiers.size());
            }
        } catch (Exception e) {
            e.printStackTrace();
            return;
        }

        SwingUtilities.invokeLater(new Runnable() {
            @Override
            public void run() {
                new QRCodeGeneratorGUI(sessions).setVisible(true);
            }
        });
    }
}
