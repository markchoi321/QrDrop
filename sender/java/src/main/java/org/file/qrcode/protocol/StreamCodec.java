package org.file.qrcode.protocol;

import java.io.ByteArrayOutputStream;
import java.io.UnsupportedEncodingException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.zip.DataFormatException;
import java.util.zip.Deflater;
import java.util.zip.Inflater;

/**
 * L4 流层（CONTRACT.md 第 6 节）。
 *
 * StreamHeader（大端，54 字节 + 文件名）+ Payload。
 * 压缩用 raw deflate（无 zlib/gzip 容器）；压缩不变小时自动关闭并清 flag。
 */
public final class StreamCodec {

    public static final byte[] MAGIC = {'V', 'D'};
    public static final int VERSION = 1;
    public static final int HEADER_FIXED = 54;

    private StreamCodec() {
    }

    /** 流元数据 */
    public static final class Meta {
        public String fileName;
        public long originalSize;
        public long payloadSize;
        public byte[] sha256;
        public boolean compressed;
        /** 流头原样字节，长度 54 + fileNameLen */
        public byte[] headerBytes;
    }

    /** parseStream 的结果 */
    public static final class Parsed {
        public final Meta meta;
        public final byte[] content;

        Parsed(Meta meta, byte[] content) {
            this.meta = meta;
            this.content = content;
        }
    }

    /** buildStream 的结果 */
    public static final class Built {
        public final byte[] stream;
        public final Meta meta;

        Built(byte[] stream, Meta meta) {
            this.stream = stream;
            this.meta = meta;
        }
    }

    public static byte[] sha256(byte[] data) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(data);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("缺少 SHA-256 实现", e);
        }
    }

    /** raw deflate（nowrap = true），压缩级别 9 */
    public static byte[] deflateRaw(byte[] data) {
        Deflater def = new Deflater(Deflater.BEST_COMPRESSION, true);
        try {
            def.setInput(data);
            def.finish();
            ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(64, data.length / 2));
            byte[] buf = new byte[8192];
            while (!def.finished()) {
                int n = def.deflate(buf);
                if (n <= 0) {
                    break;
                }
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } finally {
            def.end();
        }
    }

    /** raw inflate（nowrap = true） */
    public static byte[] inflateRaw(byte[] data) {
        Inflater inf = new Inflater(true);
        try {
            inf.setInput(data);
            ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(64, data.length * 3));
            byte[] buf = new byte[8192];
            while (!inf.finished()) {
                int n;
                try {
                    n = inf.inflate(buf);
                } catch (DataFormatException e) {
                    throw new IllegalArgumentException("raw deflate 数据损坏", e);
                }
                if (n == 0) {
                    if (inf.needsInput() || inf.needsDictionary()) {
                        break;
                    }
                } else {
                    out.write(buf, 0, n);
                }
            }
            return out.toByteArray();
        } finally {
            inf.end();
        }
    }

    public static Built buildStream(byte[] content, String fileName) {
        return buildStream(content, fileName, true);
    }

    /** 构造流层字节。allowCompress = false 时强制不压缩（测试向量用）。 */
    public static Built buildStream(byte[] content, String fileName, boolean allowCompress) {
        byte[] digest = sha256(content);
        byte[] payload = content;
        boolean compressed = false;
        if (allowCompress) {
            byte[] packed = deflateRaw(content);
            // 压缩不变小则关闭：jpg/png/zip/mp4 上 deflate 会让数据变大
            if (packed.length < content.length) {
                payload = packed;
                compressed = true;
            }
        }
        byte[] fn = utf8(fileName);
        byte[] header = new byte[HEADER_FIXED + fn.length];
        header[0] = MAGIC[0];
        header[1] = MAGIC[1];
        header[2] = (byte) VERSION;
        header[3] = (byte) (compressed ? 1 : 0);
        putLong(header, 4, content.length);
        putLong(header, 12, payload.length);
        System.arraycopy(digest, 0, header, 20, 32);
        header[52] = (byte) ((fn.length >>> 8) & 0xFF);
        header[53] = (byte) (fn.length & 0xFF);
        System.arraycopy(fn, 0, header, 54, fn.length);

        byte[] stream = new byte[header.length + payload.length];
        System.arraycopy(header, 0, stream, 0, header.length);
        System.arraycopy(payload, 0, stream, header.length, payload.length);

        Meta meta = new Meta();
        meta.fileName = fileName;
        meta.originalSize = content.length;
        meta.payloadSize = payload.length;
        meta.sha256 = digest;
        meta.compressed = compressed;
        meta.headerBytes = header;
        return new Built(stream, meta);
    }

    public static Parsed parseStream(byte[] stream) {
        if (stream.length < HEADER_FIXED) {
            throw new IllegalArgumentException("流长度不足");
        }
        if (stream[0] != MAGIC[0] || stream[1] != MAGIC[1]) {
            throw new IllegalArgumentException("流头 magic 不匹配");
        }
        int version = stream[2] & 0xFF;
        if (version != VERSION) {
            throw new IllegalArgumentException("流格式版本不支持: " + version);
        }
        int flags = stream[3] & 0xFF;
        boolean compressed = (flags & 1) != 0;
        long originalSize = getLong(stream, 4);
        long payloadSize = getLong(stream, 12);
        byte[] digest = Arrays.copyOfRange(stream, 20, 52);
        int fnLen = ((stream[52] & 0xFF) << 8) | (stream[53] & 0xFF);
        String fileName = fromUtf8(stream, 54, fnLen);
        int bodyStart = 54 + fnLen;
        int bodyEnd = (int) Math.min(stream.length, bodyStart + payloadSize);
        byte[] body = Arrays.copyOfRange(stream, bodyStart, bodyEnd);
        byte[] content = compressed ? inflateRaw(body) : body;

        Meta meta = new Meta();
        meta.fileName = fileName;
        meta.originalSize = originalSize;
        meta.payloadSize = payloadSize;
        meta.sha256 = digest;
        meta.compressed = compressed;
        meta.headerBytes = Arrays.copyOfRange(stream, 0, bodyStart);
        return new Parsed(meta, content);
    }

    private static void putLong(byte[] buf, int off, long v) {
        for (int i = 0; i < 8; i++) {
            buf[off + i] = (byte) (v >>> (56 - 8 * i));
        }
    }

    private static long getLong(byte[] buf, int off) {
        long v = 0;
        for (int i = 0; i < 8; i++) {
            v = (v << 8) | (buf[off + i] & 0xFFL);
        }
        return v;
    }

    private static byte[] utf8(String s) {
        try {
            return s.getBytes("UTF-8");
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException(e);
        }
    }

    private static String fromUtf8(byte[] b, int off, int len) {
        try {
            return new String(b, off, len, "UTF-8");
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException(e);
        }
    }
}
