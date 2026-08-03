package org.file.qrcode.protocol;

import java.util.List;

/**
 * 发送会话：一次传输的全部不可变状态（设计 7.4）。
 *
 * 播放过程中可变的部分（块序号游标、档位、间隔）不在这里，见 PlaybackState。
 */
public final class SendSession {

    public final int sessionId;
    /** 源块数 */
    public final int K;
    /** 源块大小 */
    public final int T;
    /** V40 下的每帧块数，仅用于选参展示；实际每帧块数由当前档位决定 */
    public final int mAtV40;
    /** 0 = 解方程，1 = 剥洋葱 */
    public final int codec;
    public final StreamCodec.Meta meta;
    /** K 个源块，每块 T 字节，末块已补零 */
    public final byte[][] sourceBlocks;
    public final long streamLen;
    /** 额外开销 ε */
    public final double eps;
    /** 预计所需编码块数 = ceil(K × (1 + ε)) */
    public final int blocksNeeded;
    /** 该会话的档位表，m 升序 */
    public final List<QrCapacity.Tier> tiers;

    private SendSession(int sessionId, int K, int T, int mAtV40, int codec,
                        StreamCodec.Meta meta, byte[][] sourceBlocks, long streamLen,
                        double eps, int blocksNeeded, List<QrCapacity.Tier> tiers) {
        this.sessionId = sessionId;
        this.K = K;
        this.T = T;
        this.mAtV40 = mAtV40;
        this.codec = codec;
        this.meta = meta;
        this.sourceBlocks = sourceBlocks;
        this.streamLen = streamLen;
        this.eps = eps;
        this.blocksNeeded = blocksNeeded;
        this.tiers = tiers;
    }

    public boolean isLinearSolve() {
        return codec == ParamPicker.CODEC_RLNC;
    }

    public String codecName() {
        return isLinearSolve() ? "解方程" : "剥洋葱";
    }

    /** 由文件内容建立会话：压缩 -> 选参 -> 推导 sessionId -> 切源块 */
    public static SendSession create(byte[] content, String fileName) {
        StreamCodec.Built built = StreamCodec.buildStream(content, fileName);
        return create(built, content);
    }

    /** 由已构造好的流建立会话（测试向量比对时可传入强制不压缩的流）。 */
    public static SendSession create(StreamCodec.Built built, byte[] content) {
        byte[] stream = built.stream;
        ParamPicker.Params p = ParamPicker.pick(stream.length);
        return create(built, content, p.codec, p.T, p.K, p.mAtV40);
    }

    /** 指定参数建立会话，供测试向量比对使用。 */
    public static SendSession create(StreamCodec.Built built, byte[] content,
                                     int codec, int T, int K, int mAtV40) {
        byte[] stream = built.stream;
        byte[][] src = splitSourceBlocks(stream, K, T);
        int sid = SessionId.derive(StreamCodec.sha256(content), T, K, codec);
        double eps = ParamPicker.epsOf(codec, K);
        int needed = (int) Math.ceil(K * (1.0 + eps));
        return new SendSession(sid, K, T, mAtV40, codec, built.meta, src,
                stream.length, eps, needed, QrCapacity.buildTiers(T));
    }

    /** padded = stream ‖ 0x00 × (K×T − streamLen)，按 T 均分成 K 块 */
    public static byte[][] splitSourceBlocks(byte[] stream, int K, int T) {
        byte[][] out = new byte[K][];
        for (int i = 0; i < K; i++) {
            byte[] b = new byte[T];
            int off = i * T;
            int n = Math.min(T, Math.max(0, stream.length - off));
            if (n > 0) {
                System.arraycopy(stream, off, b, 0, n);
            }
            out[i] = b;
        }
        return out;
    }

    public BlockComposer newComposer() {
        return isLinearSolve() ? new LinearSolveComposer(K) : new PeelingComposer(K);
    }
}
