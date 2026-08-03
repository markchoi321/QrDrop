package org.file.qrcode.protocol;

import org.junit.Test;

/**
 * 逐条比对 protocol/vectors 下的全部向量文件。
 * 两端实现必须逐位复现这些向量，这是唯一的验收标准。
 */
public class ProtocolVectorTest {

    @Test
    public void prng() {
        VectorChecks.checkPrng();
    }

    @Test
    public void robustSolitonCdf() {
        VectorChecks.checkRsCdf();
    }

    @Test
    public void ltNeighbors() {
        VectorChecks.checkLtNeighbors();
    }

    @Test
    public void rlncCoeff() {
        VectorChecks.checkRlncCoeff();
    }

    @Test
    public void paramPicker() {
        VectorChecks.checkParams();
    }

    @Test
    public void tiers() {
        VectorChecks.checkTiers();
    }

    @Test
    public void rawDeflate() {
        VectorChecks.checkDeflate();
    }

    @Test
    public void streamAndSessionId() {
        VectorChecks.checkStreamAndSession();
    }

    @Test
    public void framesRlnc() {
        VectorChecks.checkFrames("rlnc");
    }

    @Test
    public void framesLt() {
        VectorChecks.checkFrames("lt");
    }

    @Test
    public void streamRoundTrip() {
        VectorChecks.checkStreamRoundTrip();
    }
}
