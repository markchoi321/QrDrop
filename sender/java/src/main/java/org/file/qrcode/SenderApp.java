package org.file.qrcode;

import org.file.qrcode.protocol.FrameEncoder;
import org.file.qrcode.protocol.QrCapacity;
import org.file.qrcode.protocol.SendSession;
import org.file.qrcode.protocol.SessionId;

import javax.swing.BorderFactory;
import javax.swing.Box;
import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JWindow;
import javax.swing.SwingUtilities;
import javax.swing.Timer;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.GridLayout;
import java.awt.RenderingHints;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.KeyEvent;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * QrDrop 桌面发送端（协议 v1）。
 *
 * 结构只有三块：
 *   1. 会话      —— 选文件后由 SendSession 完成压缩、选参、切源块、档位表；
 *   2. 预渲染    —— 后台线程按当前档位连续编码 + 渲染，塞进定长环形队列；
 *   3. 显示      —— Swing 定时器只做「取一帧、画出去、推进游标」，编码不落在切帧路径上。
 *
 * 游标只在帧真正显示后推进（契约 9 / 设计 10.8），并以 sessionId 为键持久化，
 * 同一文件同参数重开自动续接。换档只改 m，T/K/codec/sessionId 不变，
 * 接收端已收到的编码块继续有效；旧档已预渲染的帧按 epoch 整体作废。
 */
public final class SenderApp extends JFrame {

    /** 预渲染深度：够盖住一次编码抖动即可，太深换档时白扔 */
    private static final int RING = 8;
    private static final int TARGET_PX = 520;
    private static final int SAVE_INTERVAL_MS = 5000;
    private static final int[] FPS_OPTIONS = {2, 5, 10, 15, 20, 25, 30};

    /** 一帧预渲染成果 */
    private static final class Item {
        final int epoch;
        final int m;
        final QrRender.Symbol sym;

        Item(int epoch, int m, QrRender.Symbol sym) {
            this.epoch = epoch;
            this.m = m;
            this.sym = sym;
        }
    }

    /** 预渲染线程读取的不可变计划；换档/换文件/重置游标都是整体换一个新的 */
    private static final class Plan {
        final FrameEncoder enc;
        final int m;
        final int epoch;
        final long startId;

            Plan(FrameEncoder enc, int m, int epoch, long startId) {
            this.enc = enc;
            this.m = m;
            this.epoch = epoch;
            this.startId = startId;
        }
    }

    // 会话状态（只在 EDT 上改）
    private SendSession session;
    private PlaybackState st;
    private List<QrCapacity.Tier> tiers;
    private int tierIdx;
    private int intervalMs = 100;

    // 预渲染
    private final ArrayBlockingQueue<Item> ring = new ArrayBlockingQueue<Item>(RING);
    private volatile Plan plan;
    private volatile boolean running = true;
    private int epoch;

    // 播放
    private final Timer timer;
    private boolean playing;
    private long lastSavedAt;
    private long fpsWindowAt;
    private int fpsWindowFrames;
    private double actualFps;
    private long starved;

    // 界面
    private final QrPanel panel = new QrPanel();
    private final QrPanel fullPanel = new QrPanel();
    private final JComboBox<String> tierBox = new JComboBox<String>();
    private final JComboBox<String> fpsBox = new JComboBox<String>();
    private final JButton btnPlay = new JButton("开始播放");
    private final JLabel infoLabel = new JLabel(" ");
    private final JLabel statLabel = new JLabel(" ");
    private JWindow fullWindow;

    public SenderApp() {
        super("QrDrop 发送端（协议 v1）");
        setDefaultCloseOperation(EXIT_ON_CLOSE);
        setLayout(new BorderLayout(6, 6));
        add(buildControls(), BorderLayout.NORTH);
        panel.setPreferredSize(new Dimension(TARGET_PX, TARGET_PX));
        add(panel, BorderLayout.CENTER);
        JPanel south = new JPanel(new GridLayout(2, 1));
        south.add(infoLabel);
        south.add(statLabel);
        south.setBorder(BorderFactory.createEmptyBorder(2, 8, 6, 8));
        add(south, BorderLayout.SOUTH);
        pack();
        setLocationRelativeTo(null);

        timer = new Timer(intervalMs, new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                tick();
            }
        });
        timer.setCoalesce(false);
        startRenderThread();
        refresh();
    }

    // ------------------------------------------------------------ 界面

    private JPanel buildControls() {
        JPanel row = new JPanel(new FlowLayout(FlowLayout.LEFT, 6, 6));
        JButton btnOpen = new JButton("选择文件");
        btnOpen.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                chooseFile();
            }
        });
        btnPlay.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                togglePlay();
            }
        });
        JButton btnReset = new JButton("重置块序号");
        btnReset.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                if (session != null) {
                    st.resetCursor();
                    replan();
                    refresh();
                }
            }
        });
        JButton btnFull = new JButton("全屏");
        btnFull.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                toggleFullscreen();
            }
        });
        JButton btnDump = new JButton("导出帧转储");
        btnDump.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                exportDump();
            }
        });
        tierBox.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                int i = tierBox.getSelectedIndex();
                if (session != null && i >= 0 && i != tierIdx) {
                    tierIdx = i;
                    replan();
                    refresh();
                }
            }
        });
        for (int f : FPS_OPTIONS) {
            fpsBox.addItem(f + " fps（" + (1000 / f) + " ms）");
        }
        fpsBox.setSelectedIndex(3);
        fpsBox.addActionListener(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                setInterval(1000 / FPS_OPTIONS[fpsBox.getSelectedIndex()]);
            }
        });

        row.add(btnOpen);
        row.add(btnPlay);
        row.add(btnReset);
        row.add(btnFull);
        row.add(btnDump);
        row.add(Box.createHorizontalStrut(8));
        row.add(new JLabel("档位"));
        row.add(tierBox);
        row.add(new JLabel("帧率"));
        row.add(fpsBox);
        return row;
    }

    /** 白底、整数倍最近邻放大：非整数倍会让模块边缘出现灰度过渡，直接损害识别率 */
    private static final class QrPanel extends JPanel {
        private BufferedImage img;
        private int modules;

        QrPanel() {
            setBackground(Color.WHITE);
        }

        void show(QrRender.Symbol sym) {
            this.img = sym == null ? null : sym.image;
            this.modules = sym == null ? 0 : sym.modules;
            repaint();
        }

        @Override
        protected void paintComponent(Graphics g0) {
            super.paintComponent(g0);
            if (img == null) {
                return;
            }
            Graphics2D g = (Graphics2D) g0;
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                    RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
            int scale = Math.max(1, Math.min(getWidth(), getHeight()) / modules);
            int side = scale * modules;
            g.drawImage(img, (getWidth() - side) / 2, (getHeight() - side) / 2, side, side, null);
        }
    }

    // ------------------------------------------------------------ 会话

    private void chooseFile() {
        JFileChooser fc = new JFileChooser();
        if (fc.showOpenDialog(this) != JFileChooser.APPROVE_OPTION) {
            return;
        }
        File f = fc.getSelectedFile();
        try {
            byte[] content = readAll(f);
            stop();
            session = SendSession.create(content, f.getName());
            tiers = session.tiers;
            st = PlaybackState.load(session.sessionId);
            tierIdx = defaultTier();
            if (st.tier >= 0 && st.tier < tiers.size()) {
                tierIdx = st.tier;
            }
            if (st.intervalMs > 0) {
                setInterval(st.intervalMs);
            }
            fillTierBox();
            replan();
            refresh();
        } catch (Exception ex) {
            JOptionPane.showMessageDialog(this, "会话创建失败: " + ex.getMessage(),
                    "错误", JOptionPane.ERROR_MESSAGE);
        }
    }

    /** 默认档位：单帧容量最接近 2 KB 的档（与 Web 端一致） */
    private int defaultTier() {
        int best = 0;
        int bestDiff = Integer.MAX_VALUE;
        for (int i = 0; i < tiers.size(); i++) {
            int d = Math.abs(tiers.get(i).capacity - 2048);
            if (d < bestDiff) {
                bestDiff = d;
                best = i;
            }
        }
        return best;
    }

    private void fillTierBox() {
        tierBox.removeAllItems();
        for (int i = 0; i < tiers.size(); i++) {
            QrCapacity.Tier t = tiers.get(i);
            tierBox.addItem((i + 1) + " 档：每帧 " + t.m + " 块 / "
                    + (FrameEncoder.HEADER_LEN + t.m * session.T) + " B");
        }
        tierBox.setSelectedIndex(tierIdx);
    }

    /** 换一个预渲染计划：epoch 递增使在途的旧档帧全部作废 */
    private void replan() {
        epoch++;
        ring.clear();
        QrCapacity.Tier t = tiers.get(tierIdx);
        st.tier = tierIdx;
        st.m = t.m;
        st.qrVersion = t.version;
        st.intervalMs = intervalMs;
        plan = new Plan(new FrameEncoder(session), t.m, epoch, st.nextBlockId);
        showStill();
    }

    /** 静止显示当前游标处的一帧，供接收端取景合焦；不推进游标 */
    private void showStill() {
        if (playing) {
            return;
        }
        try {
            QrCapacity.Tier t = tiers.get(tierIdx);
            QrRender.Symbol sym = QrRender.encode(
                    new FrameEncoder(session).encodeFrame(st.baseBlockId(), t.m));
            panel.show(sym);
            if (fullWindow != null) {
                fullPanel.show(sym);
            }
        } catch (Exception e) {
            System.err.println("渲染失败: " + e);
        }
    }

    private void setInterval(int ms) {
        intervalMs = ms;
        timer.setDelay(ms);
        timer.setInitialDelay(ms);
        for (int i = 0; i < FPS_OPTIONS.length; i++) {
            if (1000 / FPS_OPTIONS[i] == ms) {
                fpsBox.setSelectedIndex(i);
                break;
            }
        }
        if (st != null) {
            st.intervalMs = ms;
        }
    }

    // ------------------------------------------------------------ 播放

    private void togglePlay() {
        if (session == null) {
            return;
        }
        if (playing) {
            stop();
        } else {
            playing = true;
            fpsWindowAt = System.currentTimeMillis();
            fpsWindowFrames = 0;
            timer.start();
        }
        refresh();
    }

    private void stop() {
        playing = false;
        timer.stop();
        if (st != null) {
            st.save();
        }
    }

    private void tick() {
        Item it;
        // 丢掉换档前塞进来的旧帧
        while ((it = ring.poll()) != null && it.epoch != epoch) {
            it = null;
        }
        if (it == null) {
            // 缓冲空：保持当前帧继续显示，绝不换上没准备好的内容，也不推进游标
            starved++;
            return;
        }
        panel.show(it.sym);
        if (fullWindow != null) {
            fullPanel.show(it.sym);
        }
        st.advanceAfterShown(it.m);

        long now = System.currentTimeMillis();
        fpsWindowFrames++;
        if (now - fpsWindowAt >= 1000) {
            actualFps = fpsWindowFrames * 1000.0 / (now - fpsWindowAt);
            fpsWindowAt = now;
            fpsWindowFrames = 0;
        }
        if (now - lastSavedAt >= SAVE_INTERVAL_MS) {
            lastSavedAt = now;
            st.save();
        }
        refreshStats(it.sym.version);
    }

    private void startRenderThread() {
        Thread t = new Thread("qr-render") {
            @Override
            public void run() {
                int localEpoch = -1;
                long produceId = 0;
                while (running) {
                    Plan p = plan;
                    if (p == null) {
                        sleep(50);
                        continue;
                    }
                    if (p.epoch != localEpoch) {
                        localEpoch = p.epoch;
                        produceId = p.startId;
                    }
                    Item item;
                    try {
                        byte[] frame = p.enc.encodeFrame((int) produceId, p.m);
                        item = new Item(localEpoch, p.m, QrRender.encode(frame));
                    } catch (Exception e) {
                        System.err.println("渲染失败: " + e);
                        sleep(200);
                        continue;
                    }
                    try {
                        // 队列满就等；等待期间换了档就丢掉这一帧重来
                        while (running && !ring.offer(item, 50, TimeUnit.MILLISECONDS)) {
                            if (plan.epoch != localEpoch) {
                                item = null;
                                break;
                            }
                        }
                    } catch (InterruptedException e) {
                        return;
                    }
                    if (item != null) {
                        produceId = (produceId + p.m) & 0xFFFFFFFFL;
                    }
                }
            }

            private void sleep(int ms) {
                try {
                    Thread.sleep(ms);
                } catch (InterruptedException e) {
                    running = false;
                }
            }
        };
        t.setDaemon(true);
        t.setPriority(Thread.NORM_PRIORITY - 1);
        t.start();
    }

    // ------------------------------------------------------------ 全屏

    private void toggleFullscreen() {
        if (fullWindow != null) {
            fullWindow.dispose();
            fullWindow = null;
            return;
        }
        if (session == null) {
            return;
        }
        fullWindow = new JWindow(this);
        fullPanel.setBackground(Color.WHITE);
        fullWindow.getContentPane().add(fullPanel);
        fullWindow.setBounds(getGraphicsConfiguration().getBounds());
        fullWindow.setVisible(true);
        // ESC 或点击退出
        fullPanel.registerKeyboardAction(new ActionListener() {
            public void actionPerformed(ActionEvent e) {
                toggleFullscreen();
            }
        }, javax.swing.KeyStroke.getKeyStroke(KeyEvent.VK_ESCAPE, 0),
                JPanel.WHEN_IN_FOCUSED_WINDOW);
        fullPanel.requestFocusInWindow();
        showStill();
    }

    // ------------------------------------------------------------ 转储

    /** 导出一轮帧（契约 14 节：连续的 [4B 大端长度][帧字节]），供 crosscheck.py 校验 */
    private void exportDump() {
        if (session == null) {
            return;
        }
        JFileChooser fc = new JFileChooser();
        fc.setSelectedFile(new File(SessionId.toHex(session.sessionId) + ".vddump"));
        if (fc.showSaveDialog(this) != JFileChooser.APPROVE_OPTION) {
            return;
        }
        int m = tiers.get(tierIdx).m;
        int frames = (session.blocksNeeded + m - 1) / m;
        OutputStream out = null;
        try {
            out = new java.io.BufferedOutputStream(new FileOutputStream(fc.getSelectedFile()));
            FrameEncoder enc = new FrameEncoder(session);
            for (int i = 0, base = 0; i < frames; i++, base += m) {
                byte[] frame = enc.encodeFrame(base, m);
                int n = frame.length;
                out.write(n >>> 24);
                out.write(n >>> 16);
                out.write(n >>> 8);
                out.write(n);
                out.write(frame);
            }
            out.close();
            out = null;
            JOptionPane.showMessageDialog(this, "已导出 " + frames + " 帧");
        } catch (IOException e) {
            JOptionPane.showMessageDialog(this, "导出失败: " + e.getMessage(),
                    "错误", JOptionPane.ERROR_MESSAGE);
        } finally {
            if (out != null) {
                try {
                    out.close();
                } catch (IOException ignored) {
                    // 忽略
                }
            }
        }
    }

    // ------------------------------------------------------------ 刷新

    private void refresh() {
        btnPlay.setText(playing ? "暂停" : "开始播放");
        if (session == null) {
            infoLabel.setText("请选择文件");
            statLabel.setText(" ");
            return;
        }
        infoLabel.setText(String.format(
                "%s   原始 %s，流层 %s%s   方案 %s   T=%d  K=%d  会话 %s",
                session.meta.fileName, size(session.meta.originalSize), size(session.streamLen),
                session.meta.compressed ? "（已压缩）" : "", session.codecName(),
                session.T, session.K, SessionId.toHex(session.sessionId)));
        refreshStats(tiers.get(tierIdx).version);
    }

    private void refreshStats(int version) {
        QrCapacity.Tier t = tiers.get(tierIdx);
        long sent = st.nextBlockId;
        statLabel.setText(String.format(
                "V%d  每帧 %d 块/%d B（载荷率 %.0f%%）   已发 %d/%d 块（%.0f%%）   已播 %d 帧   实测 %.1f fps   缺帧 %d",
                version, t.m, FrameEncoder.HEADER_LEN + t.m * session.T,
                t.payloadRate(session.T) * 100,
                sent, session.blocksNeeded, Math.min(100.0, sent * 100.0 / session.blocksNeeded),
                st.framesShown, actualFps, starved));
    }

    private static String size(long n) {
        if (n < 1024) {
            return n + " B";
        }
        if (n < 1024 * 1024) {
            return String.format("%.1f KB", n / 1024.0);
        }
        return String.format("%.2f MB", n / 1048576.0);
    }

    private static byte[] readAll(File f) throws IOException {
        long len = f.length();
        if (len > Integer.MAX_VALUE) {
            throw new IOException("文件过大");
        }
        byte[] buf = new byte[(int) len];
        java.io.DataInputStream in = new java.io.DataInputStream(new java.io.FileInputStream(f));
        try {
            in.readFully(buf);
        } finally {
            in.close();
        }
        return buf;
    }

    public static void main(String[] args) {
        SwingUtilities.invokeLater(new Runnable() {
            public void run() {
                try {
                    javax.swing.UIManager.setLookAndFeel(
                            javax.swing.UIManager.getSystemLookAndFeelClassName());
                } catch (Exception ignored) {
                    // 用默认外观
                }
                new SenderApp().setVisible(true);
            }
        });
    }
}
