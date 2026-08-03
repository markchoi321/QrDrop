package org.file.qrcode.protocol;

import java.util.zip.CRC32;

/**
 * L2 帧层编码器（CONTRACT.md 第 8 节）。
 *
 * 帧 = 20 字节帧头 + m 个 T 字节编码块（块无头）。
 * 第 i 块的序号 = baseBlockId + i（uint32 回绕）。
 */
public final class FrameEncoder {

    public static final int FRAME_MAGIC = 0x56;
    public static final int PROTOCOL_VERSION = 1;
    public static final int HEADER_LEN = 20;

    private final SendSession session;
    private final BlockComposer composer;

    public FrameEncoder(SendSession session) {
        this.session = session;
        this.composer = session.newComposer();
    }

    public FrameEncoder(SendSession session, BlockComposer composer) {
        this.session = session;
        this.composer = composer;
    }

    public SendSession getSession() {
        return session;
    }

    /** 产出完整一帧字节：帧头 + m×T 载荷。 */
    public byte[] encodeFrame(int baseBlockId, int m) {
        int T = session.T;
        byte[] frame = new byte[HEADER_LEN + m * T];
        for (int i = 0; i < m; i++) {
            int bid = baseBlockId + i;
            int[] nb = composer.neighborsOf(bid);
            int off = HEADER_LEN + i * T;
            for (int k = 0; k < nb.length; k++) {
                byte[] s = session.sourceBlocks[nb[k]];
                for (int j = 0; j < T; j++) {
                    frame[off + j] ^= s[j];
                }
            }
        }
        int flags = (PROTOCOL_VERSION << 4)
                | ((session.meta.compressed ? 1 : 0) << 3)
                | (session.codec << 2);
        frame[0] = (byte) FRAME_MAGIC;
        frame[1] = (byte) flags;
        putInt(frame, 2, session.sessionId);
        frame[6] = (byte) ((session.K >>> 16) & 0xFF);
        frame[7] = (byte) ((session.K >>> 8) & 0xFF);
        frame[8] = (byte) (session.K & 0xFF);
        frame[9] = (byte) ((T >>> 8) & 0xFF);
        frame[10] = (byte) (T & 0xFF);
        frame[11] = (byte) m;
        putInt(frame, 12, baseBlockId);

        CRC32 crc = new CRC32();
        crc.update(frame, HEADER_LEN, m * T);
        putInt(frame, 16, (int) crc.getValue());
        return frame;
    }

    private static void putInt(byte[] buf, int off, int v) {
        buf[off] = (byte) (v >>> 24);
        buf[off + 1] = (byte) (v >>> 16);
        buf[off + 2] = (byte) (v >>> 8);
        buf[off + 3] = (byte) v;
    }
}
