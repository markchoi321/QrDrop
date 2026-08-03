package org.file.qrcode;

import org.file.qrcode.protocol.SessionId;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.util.Properties;

/**
 * 发送端播放状态（设计 10.8）：与 SendSession 的不可变参数分开管理。
 *
 * 游标 nextBlockId 只在帧真正显示后推进。预取线程提前生成的帧不推进游标——
 * 否则换档时作废的那些 blockId 会在序列里留下永远不出现的空洞，
 * 破坏 11.1 标定中"由 maxBlockId / m 反推已播帧数"的公式。
 *
 * 以 sessionId 为键持久化到 ~/.visiondrop/playback/<sessionId>.state，
 * 重启后同一文件推导出同一 sessionId，游标从上次位置续推。
 */
public class PlaybackState {

    /** 状态目录 */
    private static final String DIR_NAME = ".visiondrop" + File.separator + "playback";

    public final int sessionId;
    /** 块序号游标，仅在帧真正显示后推进 */
    public long nextBlockId;
    /** 当前档位序号，从 0 起（界面上展示为 tier+1） */
    public int tier;
    /** 档位对应的 QR 版本 */
    public int qrVersion;
    /** 当前档位的每帧块数 */
    public int m;
    /** 显示间隔 D，毫秒 */
    public int intervalMs;
    /** 已播帧数，仅用于统计 */
    public long framesShown;

    public PlaybackState(int sessionId) {
        this.sessionId = sessionId;
    }

    /** 帧真正显示后调用：推进游标并累计帧数 */
    public void advanceAfterShown(int shownM) {
        nextBlockId = (nextBlockId + shownM) & 0xFFFFFFFFL;
        framesShown++;
    }

    /** 重置块序号（界面上的"重置块序号"按钮） */
    public void resetCursor() {
        nextBlockId = 0;
        framesShown = 0;
    }

    /** 游标的 uint32 表示，供帧头使用 */
    public int baseBlockId() {
        return (int) nextBlockId;
    }

    private static File stateFile(int sessionId) {
        File dir = new File(System.getProperty("user.home"), DIR_NAME);
        return new File(dir, SessionId.toHex(sessionId) + ".state");
    }

    /** 读取持久化状态；不存在或损坏时返回一个全新状态 */
    public static PlaybackState load(int sessionId) {
        PlaybackState st = new PlaybackState(sessionId);
        File f = stateFile(sessionId);
        if (!f.isFile()) {
            return st;
        }
        FileInputStream in = null;
        try {
            in = new FileInputStream(f);
            Properties p = new Properties();
            BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
            p.load(r);
            st.nextBlockId = Long.parseLong(p.getProperty("nextBlockId", "0"));
            st.framesShown = Long.parseLong(p.getProperty("framesShown", "0"));
            st.tier = Integer.parseInt(p.getProperty("tier", "0"));
            st.qrVersion = Integer.parseInt(p.getProperty("qrVersion", "0"));
            st.m = Integer.parseInt(p.getProperty("m", "0"));
            st.intervalMs = Integer.parseInt(p.getProperty("intervalMs", "0"));
        } catch (Exception e) {
            // 损坏就当作新会话，不影响传输
            return new PlaybackState(sessionId);
        } finally {
            closeQuietly(in);
        }
        return st;
    }

    /** 写回持久化状态；失败只打印告警，不影响播放 */
    public void save() {
        File f = stateFile(sessionId);
        File dir = f.getParentFile();
        if (!dir.isDirectory() && !dir.mkdirs()) {
            System.err.println("警告: 无法创建状态目录 " + dir);
            return;
        }
        Writer w = null;
        try {
            Properties p = new Properties();
            p.setProperty("sessionId", SessionId.toHex(sessionId));
            p.setProperty("nextBlockId", Long.toString(nextBlockId));
            p.setProperty("framesShown", Long.toString(framesShown));
            p.setProperty("tier", Integer.toString(tier));
            p.setProperty("qrVersion", Integer.toString(qrVersion));
            p.setProperty("m", Integer.toString(m));
            p.setProperty("intervalMs", Integer.toString(intervalMs));
            w = new OutputStreamWriter(new FileOutputStream(f), "UTF-8");
            p.store(w, "VisionDrop 发送端播放状态");
        } catch (IOException e) {
            System.err.println("警告: 播放状态保存失败 " + e.getMessage());
        } finally {
            closeQuietly(w);
        }
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (IOException ignored) {
                // 忽略
            }
        }
    }
}
