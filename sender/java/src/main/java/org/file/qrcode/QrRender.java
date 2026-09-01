package org.file.qrcode;

import com.google.zxing.EncodeHintType;
import com.google.zxing.WriterException;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import com.google.zxing.qrcode.decoder.Mode;
import com.google.zxing.qrcode.encoder.ByteMatrix;
import com.google.zxing.qrcode.encoder.Encoder;
import com.google.zxing.qrcode.encoder.QRCode;

import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.UnsupportedEncodingException;
import java.util.EnumMap;
import java.util.Map;

/**
 * QR 渲染（ZXing 2.3.0 core）。
 *
 * 只用 Encoder 直接拿模块矩阵，不走 QRCodeWriter/MatrixToImageWriter：
 * 少一次 BitMatrix 拷贝，也不需要 javase 依赖。
 *
 * 帧字节按 ISO-8859-1 逐字节映射成 String 交给 ZXing，走字节模式；
 * 不设 CHARACTER_SET hint（设了会插入 ECI 段，接收端取字节模式段的逻辑会错位）。
 *
 * 2.3.0 没有 QR_VERSION hint，版本由 ZXing 按载荷长度取最小可容纳版本。
 * 档位的 m 本就是由某个版本的容量算出来的（帧长 = 20 + m×T > 该版本容量 − T），
 * 实测全 T 范围内最小落点是 V10，仍在「16 bit 字符计数」分支内，
 * 接收端按契约 11.7 取字节模式段不受影响。
 */
public final class QrRender {

    /** 静区宽度，单位模块（契约第 1 节：margin 2） */
    public static final int MARGIN = 2;

    private static final Map<EncodeHintType, Object> HINTS =
            new EnumMap<EncodeHintType, Object>(EncodeHintType.class);

    static {
        HINTS.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.L);
    }

    private QrRender() {
    }

    /** 一次编码的结果：1 模块 = 1 像素的黑白位图 + 实际 QR 版本 */
    public static final class Symbol {
        public final BufferedImage image;
        public final int version;
        /** 含静区的边长（模块数） */
        public final int modules;

        Symbol(BufferedImage image, int version, int modules) {
            this.image = image;
            this.version = version;
            this.modules = modules;
        }
    }

    /** 帧字节 -> 含静区的模块位图。放大交给绘制时的整数倍最近邻。 */
    public static Symbol encode(byte[] frame) throws WriterException {
        QRCode qr = Encoder.encode(latin1(frame), ErrorCorrectionLevel.L, HINTS);
        if (qr.getMode() != Mode.BYTE) {
            // 帧里含 CRC，几乎不可能整帧落在数字/字母数字字符集内；真发生了必须报错，
            // 因为接收端只解字节模式段
            throw new WriterException("ZXing 选到了非字节模式: " + qr.getMode());
        }
        ByteMatrix m = qr.getMatrix();
        int n = m.getWidth();
        int side = n + 2 * MARGIN;
        BufferedImage img = new BufferedImage(side, side, BufferedImage.TYPE_BYTE_BINARY);
        Graphics2D g = img.createGraphics();
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, side, side);
        g.setColor(Color.BLACK);
        byte[][] a = m.getArray();
        // 逐行合并连续黑模块，减少 fillRect 次数
        for (int y = 0; y < n; y++) {
            byte[] row = a[y];
            int x = 0;
            while (x < n) {
                if (row[x] != 1) {
                    x++;
                    continue;
                }
                int start = x;
                while (x < n && row[x] == 1) {
                    x++;
                }
                g.fillRect(start + MARGIN, y + MARGIN, x - start, 1);
            }
        }
        g.dispose();
        return new Symbol(img, qr.getVersion().getVersionNumber(), side);
    }

    private static String latin1(byte[] data) {
        try {
            return new String(data, "ISO-8859-1");
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException("缺少 ISO-8859-1", e);
        }
    }
}
