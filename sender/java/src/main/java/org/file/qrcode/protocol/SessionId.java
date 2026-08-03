package org.file.qrcode.protocol;

/**
 * L5 会话标识（CONTRACT.md 第 7 节）。
 *
 * sessionId = SHA256(sha256(文件内容) ‖ T(2B 大端) ‖ K(3B 大端) ‖ codec(1B)) 的前 4 字节，
 * 按大端解释为 uint32。确定性推导使同一文件同一参数的重复传输天然续接。
 */
public final class SessionId {

    private SessionId() {
    }

    public static int derive(byte[] contentSha256, int T, int K, int codec) {
        byte[] buf = new byte[contentSha256.length + 6];
        System.arraycopy(contentSha256, 0, buf, 0, contentSha256.length);
        int p = contentSha256.length;
        buf[p] = (byte) ((T >>> 8) & 0xFF);
        buf[p + 1] = (byte) (T & 0xFF);
        buf[p + 2] = (byte) ((K >>> 16) & 0xFF);
        buf[p + 3] = (byte) ((K >>> 8) & 0xFF);
        buf[p + 4] = (byte) (K & 0xFF);
        buf[p + 5] = (byte) codec;
        byte[] d = StreamCodec.sha256(buf);
        return ((d[0] & 0xFF) << 24) | ((d[1] & 0xFF) << 16)
                | ((d[2] & 0xFF) << 8) | (d[3] & 0xFF);
    }

    /** 8 位小写 hex 表示 */
    public static String toHex(int sessionId) {
        return String.format("%08x", sessionId & 0xFFFFFFFFL);
    }
}
