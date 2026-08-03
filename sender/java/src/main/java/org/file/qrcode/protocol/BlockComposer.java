package org.file.qrcode.protocol;

/**
 * 编码块组成的推导接口：blockId -> 参与异或的源块索引集合（升序、互异）。
 * 两端必须逐位一致，是跨语言测试向量的验证对象。
 */
public interface BlockComposer {

    /** 返回参与异或的源块索引，升序。 */
    int[] neighborsOf(int blockId);
}
