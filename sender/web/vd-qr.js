/*
 * QrDrop Web 发送端 —— QR 编码器（纯 ES5，无任何依赖）
 *
 * 只实现本协议需要的子集：字节模式、ECC=L、版本 1–40、不设 ECI/字符集提示。
 * 分块表由 QR 规范第一性推导并与项目容量表（refimpl.py QR_CAPACITY）逐版本
 * 核对一致；数据码字流（模式头 + 载荷 + 终止符 + 0xEC/0x11 填充）由
 * protocol/vectors/qr_codewords.txt 向量验收。
 */
(function (root, factory) {
    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.VDQR = factory();
    }
}(typeof self !== "undefined" ? self : this, function () {
    "use strict";

    /* ---------------------------------------------------- 版本参数表（ECC=L） */

    /* 每块纠错码字数 E，下标 = 版本 */
    var EC_PER_BLOCK = [0,
        7, 10, 15, 20, 26, 18, 20, 24, 30, 18,
        20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
        28, 28, 30, 30, 26, 28, 30, 30, 30, 30,
        30, 30, 30, 30, 30, 30, 30, 30, 30, 30];

    /* RS 分块总数 B，下标 = 版本 */
    var NUM_BLOCKS = [0,
        1, 1, 1, 1, 1, 2, 2, 2, 2, 4,
        4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
        8, 9, 9, 10, 12, 12, 12, 13, 14, 15,
        16, 17, 18, 19, 19, 20, 21, 22, 24, 25];

    /* 数据码字总数 DC，下标 = 版本（分块规则：前 B-DC%B 块各 floor(DC/B) 字节，
       其余各 +1 字节，与 QR 规范一致） */
    var DATA_CODEWORDS = [0,
        19, 34, 55, 80, 108, 136, 156, 194, 232, 274,
        324, 370, 428, 461, 523, 589, 647, 721, 795, 861,
        932, 1006, 1094, 1174, 1276, 1370, 1468, 1531, 1631, 1735,
        1843, 1955, 2071, 2191, 2306, 2434, 2566, 2702, 2812, 2956];

    /* 对齐图案中心坐标，下标 = 版本 */
    var ALIGN = [null, [],
        [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
        [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
        [6, 30, 54], [6, 32, 58], [6, 34, 62], [6, 26, 46, 66],
        [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78],
        [6, 30, 56, 82], [6, 30, 58, 86], [6, 34, 62, 90],
        [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102],
        [6, 28, 54, 80, 106], [6, 32, 58, 84, 110], [6, 30, 58, 86, 114],
        [6, 34, 62, 90, 118], [6, 26, 50, 74, 98, 122],
        [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130],
        [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138],
        [6, 30, 58, 86, 114, 142], [6, 34, 62, 90, 118, 146],
        [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154],
        [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162],
        [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170]];

    /* ---------------------------------------------------- GF(256) */

    var GF_EXP = new Array(512), GF_LOG = new Array(256);
    (function () {
        var x = 1;
        for (var i = 0; i < 255; i++) {
            GF_EXP[i] = x;
            GF_LOG[x] = i;
            x <<= 1;
            if (x & 0x100) { x ^= 0x11D; }
        }
        for (var j = 255; j < 512; j++) { GF_EXP[j] = GF_EXP[j - 255]; }
    })();

    function gfMul(a, b) {
        if (a === 0 || b === 0) { return 0; }
        return GF_EXP[GF_LOG[a] + GF_LOG[b]];
    }

    /* 生成多项式缓存：degree -> 系数数组（首一，最高次在前）
       g(x) = (x + a^0)(x + a^1)…(x + a^(degree-1)) */
    var GEN_CACHE = {};
    function genPoly(degree) {
        if (GEN_CACHE[degree]) { return GEN_CACHE[degree]; }
        var poly = [1];
        for (var d = 0; d < degree; d++) {
            var next = new Array(poly.length + 1);
            var i;
            for (i = 0; i < next.length; i++) { next[i] = 0; }
            for (i = 0; i < poly.length; i++) {
                next[i] ^= poly[i];                        /* 乘 x 项 */
                next[i + 1] ^= gfMul(poly[i], GF_EXP[d]);  /* 乘 a^d 项 */
            }
            poly = next;
        }
        GEN_CACHE[degree] = poly;
        return poly;
    }

    /* RS 纠错码字：data 为 Uint8Array，返回 Uint8Array(degree) */
    function rsEncode(data, degree) {
        var gen = genPoly(degree);
        var res = new Uint8Array(degree);
        for (var i = 0; i < data.length; i++) {
            var factor = data[i] ^ res[0];
            /* 左移一格 */
            for (var j = 0; j < degree - 1; j++) { res[j] = res[j + 1]; }
            res[degree - 1] = 0;
            if (factor !== 0) {
                var lf = GF_LOG[factor];
                for (var k = 0; k < degree; k++) {
                    /* gen[0] 恒为 1（首一），余数只需异或 gen[k+1] 的贡献 */
                    var g = gen[k + 1];
                    if (g !== 0) { res[k] ^= GF_EXP[(GF_LOG[g] + lf) % 255]; }
                }
            }
        }
        return res;
    }

    /* ---------------------------------------------------- 数据码字 */

    /*
     * 构造数据码字流：模式指示符 0100 + 字符计数（V1-9 为 8 位，V10+ 为 16 位）
     * + 数据 + 终止符 + 0xEC/0x11 交替填充，总长 = DATA_CODEWORDS[version]。
     */
    function buildDataCodewords(version, data) {
        var dcLen = DATA_CODEWORDS[version];
        var countBits = version < 10 ? 8 : 16;
        /* 终止符可缩短到 0 位，故只要模式头 + 数据位放得下即可 */
        if (4 + countBits + data.length * 8 > dcLen * 8) {
            throw new Error("数据超出版本容量: V" + version + " len=" + data.length);
        }
        var out = new Uint8Array(dcLen);
        var bitPos = 0;
        function putBits(value, n) {
            for (var b = n - 1; b >= 0; b--) {
                if ((value >>> b) & 1) { out[bitPos >> 3] |= 0x80 >> (bitPos & 7); }
                bitPos++;
            }
        }
        putBits(4, 4);                    /* 字节模式 0100 */
        putBits(data.length, countBits);
        for (var i = 0; i < data.length; i++) { putBits(data[i], 8); }
        /* 终止符：至多 4 个 0 位；putBits(0) 只推进指针 */
        var remain = dcLen * 8 - bitPos;
        putBits(0, remain < 4 ? remain : 4);
        /* 补齐到字节边界（缓冲区初始即 0，推进即可） */
        if ((bitPos & 7) !== 0) { bitPos += 8 - (bitPos & 7); }
        /* 填充字节 0xEC / 0x11 交替 */
        var pad = 0xEC;
        while (bitPos < dcLen * 8) {
            out[bitPos >> 3] = pad;
            pad = pad === 0xEC ? 0x11 : 0xEC;
            bitPos += 8;
        }
        return out;
    }

    /* 分块 + RS + 交织，返回最终码字序列 Uint8Array */
    function buildFinalCodewords(version, dataCodewords) {
        var ec = EC_PER_BLOCK[version];
        var nb = NUM_BLOCKS[version];
        var dc = DATA_CODEWORDS[version];
        var shortLen = Math.floor(dc / nb);
        var longCount = dc % nb;              /* 后 longCount 块各多 1 字节 */
        var blocks = [], ecBlocks = [];
        var off = 0, i, j;
        for (i = 0; i < nb; i++) {
            var len = shortLen + (i >= nb - longCount ? 1 : 0);
            var blk = dataCodewords.subarray(off, off + len);
            off += len;
            blocks.push(blk);
            ecBlocks.push(rsEncode(blk, ec));
        }
        var total = dc + nb * ec;
        var out = new Uint8Array(total);
        var pos = 0;
        var maxLen = shortLen + (longCount > 0 ? 1 : 0);
        for (j = 0; j < maxLen; j++) {
            for (i = 0; i < nb; i++) {
                if (j < blocks[i].length) { out[pos++] = blocks[i][j]; }
            }
        }
        for (j = 0; j < ec; j++) {
            for (i = 0; i < nb; i++) { out[pos++] = ecBlocks[i][j]; }
        }
        return out;
    }

    /* ---------------------------------------------------- 矩阵 */

    /*
     * 模块矩阵用 Uint8Array(n*n) 表示：0/1 = 数据区亮/暗，另用 func 矩阵标记
     * 功能图形（含格式/版本信息预留区），数据填充与掩码都跳过功能区。
     */
    function buildMatrix(version, finalCodewords, maskId) {
        var n = 17 + 4 * version;
        var mat = new Uint8Array(n * n);
        var func = new Uint8Array(n * n);
        var i, j, r, c;

        function set(row, col, dark, isFunc) {
            mat[row * n + col] = dark ? 1 : 0;
            if (isFunc) { func[row * n + col] = 1; }
        }

        /* 定位图形 + 分隔符 */
        function finder(row, col) {
            for (var dr = -1; dr <= 7; dr++) {
                for (var dc = -1; dc <= 7; dc++) {
                    var rr = row + dr, cc = col + dc;
                    if (rr < 0 || rr >= n || cc < 0 || cc >= n) { continue; }
                    var dark = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6 &&
                        (dr === 0 || dr === 6 || dc === 0 || dc === 6 ||
                         (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
                    set(rr, cc, dark, true);
                }
            }
        }
        finder(0, 0);
        finder(0, n - 7);
        finder(n - 7, 0);

        /* 时序图形 */
        for (i = 8; i < n - 8; i++) {
            if (!func[6 * n + i]) { set(6, i, i % 2 === 0, true); }
            if (!func[i * n + 6]) { set(i, 6, i % 2 === 0, true); }
        }

        /* 对齐图案（仅跳过与三个定位图形重叠的角；行 6 / 列 6 上的
           对齐图案与时序图形取值一致，正常绘制） */
        var ap = ALIGN[version];
        for (i = 0; i < ap.length; i++) {
            for (j = 0; j < ap.length; j++) {
                r = ap[i]; c = ap[j];
                if ((r <= 8 && c <= 8) || (r <= 8 && c >= n - 9) ||
                    (r >= n - 9 && c <= 8)) { continue; }
                for (var dr = -2; dr <= 2; dr++) {
                    for (var dc = -2; dc <= 2; dc++) {
                        var dark = dr === -2 || dr === 2 || dc === -2 || dc === 2 ||
                            (dr === 0 && dc === 0);
                        set(r + dr, c + dc, dark, true);
                    }
                }
            }
        }

        /* 格式信息预留区（内容最后写） */
        for (i = 0; i <= 8; i++) {
            if (!func[8 * n + i]) { set(8, i, 0, true); }
            if (!func[i * n + 8]) { set(i, 8, 0, true); }
        }
        for (i = 0; i < 8; i++) {
            if (!func[8 * n + (n - 1 - i)]) { set(8, n - 1 - i, 0, true); }
            if (!func[(n - 1 - i) * n + 8]) { set(n - 1 - i, 8, 0, true); }
        }
        /* 固定暗模块 */
        set(n - 8, 8, 1, true);

        /* 版本信息（V7 起） */
        if (version >= 7) {
            var vinfo = versionInfoBits(version);
            for (i = 0; i < 18; i++) {
                var bit = (vinfo >>> i) & 1;
                var rr2 = Math.floor(i / 3), cc2 = n - 11 + (i % 3);
                set(rr2, cc2, bit, true);
                set(cc2, rr2, bit, true);
            }
        }

        /* 数据填充：右下角起，双列锯齿，跳过第 6 列 */
        var bitIndex = 0;
        var totalBits = finalCodewords.length * 8;
        var upward = true;
        for (c = n - 1; c >= 1; c -= 2) {
            if (c === 6) { c = 5; }
            for (var step = 0; step < n; step++) {
                r = upward ? n - 1 - step : step;
                for (var side = 0; side < 2; side++) {
                    var col = c - side;
                    if (func[r * n + col]) { continue; }
                    var v = 0;
                    if (bitIndex < totalBits) {
                        v = (finalCodewords[bitIndex >> 3] >>> (7 - (bitIndex & 7))) & 1;
                    }
                    bitIndex++;
                    /* 掩码只作用于数据区 */
                    if (maskFn(maskId, r, col)) { v ^= 1; }
                    mat[r * n + col] = v;
                }
            }
            upward = !upward;
        }

        /* 格式信息（ECC=L，含掩码号） */
        var fmt = formatInfoBits(maskId);
        var fb = new Array(15);
        for (i = 0; i < 15; i++) { fb[i] = (fmt >>> i) & 1; }
        /* 副本一：绕左上角。fb[14] 是最高位 */
        var coordsA = [
            [8, 0], [8, 1], [8, 2], [8, 3], [8, 4], [8, 5], [8, 7], [8, 8],
            [7, 8], [5, 8], [4, 8], [3, 8], [2, 8], [1, 8], [0, 8]];
        for (i = 0; i < 15; i++) {
            mat[coordsA[i][0] * n + coordsA[i][1]] = fb[14 - i];
        }
        /* 副本二：左下 7 格竖排 + 右上 8 格横排 */
        for (i = 0; i < 7; i++) {
            mat[(n - 1 - i) * n + 8] = fb[14 - i];
        }
        for (i = 0; i < 8; i++) {
            mat[8 * n + (n - 8 + i)] = fb[7 - i];
        }

        return { n: n, mat: mat, func: func };
    }

    function maskFn(id, r, c) {
        switch (id) {
            case 0: return (r + c) % 2 === 0;
            case 1: return r % 2 === 0;
            case 2: return c % 3 === 0;
            case 3: return (r + c) % 3 === 0;
            case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
            case 5: return (r * c) % 2 + (r * c) % 3 === 0;
            case 6: return ((r * c) % 2 + (r * c) % 3) % 2 === 0;
            default: return ((r + c) % 2 + (r * c) % 3) % 2 === 0;
        }
    }

    /* BCH(15,5)：格式信息 = (ECC 位 << 3 | 掩码号) + 10 位纠错，再异或 0x5412 */
    function formatInfoBits(maskId) {
        var data = (1 << 3) | maskId;      /* ECC=L 的指示位是 01 */
        var v = data << 10;
        for (var i = 14; i >= 10; i--) {
            if ((v >>> i) & 1) { v ^= 0x537 << (i - 10); }
        }
        return ((data << 10) | v) ^ 0x5412;
    }

    /* BCH(18,6)：版本信息 = 版本号 6 位 + 12 位纠错 */
    function versionInfoBits(version) {
        var v = version << 12;
        for (var i = 17; i >= 12; i--) {
            if ((v >>> i) & 1) { v ^= 0x1F25 << (i - 12); }
        }
        return (version << 12) | v;
    }

    /* ---------------------------------------------------- 掩码评估 */

    function penalty(qr) {
        var n = qr.n, mat = qr.mat;
        var score = 0;
        var r, c, i;

        /* 规则一：行/列连续同色 >= 5 */
        for (r = 0; r < n; r++) {
            var runColor = -1, runLen = 0;
            for (c = 0; c < n; c++) {
                var v = mat[r * n + c];
                if (v === runColor) { runLen++; } else {
                    if (runLen >= 5) { score += 3 + runLen - 5; }
                    runColor = v; runLen = 1;
                }
            }
            if (runLen >= 5) { score += 3 + runLen - 5; }
        }
        for (c = 0; c < n; c++) {
            var runColor2 = -1, runLen2 = 0;
            for (r = 0; r < n; r++) {
                var v2 = mat[r * n + c];
                if (v2 === runColor2) { runLen2++; } else {
                    if (runLen2 >= 5) { score += 3 + runLen2 - 5; }
                    runColor2 = v2; runLen2 = 1;
                }
            }
            if (runLen2 >= 5) { score += 3 + runLen2 - 5; }
        }

        /* 规则二：2x2 同色块 */
        for (r = 0; r < n - 1; r++) {
            for (c = 0; c < n - 1; c++) {
                var a = mat[r * n + c];
                if (a === mat[r * n + c + 1] && a === mat[(r + 1) * n + c] &&
                    a === mat[(r + 1) * n + c + 1]) { score += 3; }
            }
        }

        /* 规则三：1011101 前/后接 0000 */
        var P1 = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
        var P2 = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
        for (r = 0; r < n; r++) {
            for (c = 0; c <= n - 11; c++) {
                var m1 = true, m2 = true;
                for (i = 0; i < 11; i++) {
                    var vv = mat[r * n + c + i];
                    if (vv !== P1[i]) { m1 = false; }
                    if (vv !== P2[i]) { m2 = false; }
                    if (!m1 && !m2) { break; }
                }
                if (m1) { score += 40; }
                if (m2) { score += 40; }
            }
        }
        for (c = 0; c < n; c++) {
            for (r = 0; r <= n - 11; r++) {
                var m3 = true, m4 = true;
                for (i = 0; i < 11; i++) {
                    var vv2 = mat[(r + i) * n + c];
                    if (vv2 !== P1[i]) { m3 = false; }
                    if (vv2 !== P2[i]) { m4 = false; }
                    if (!m3 && !m4) { break; }
                }
                if (m3) { score += 40; }
                if (m4) { score += 40; }
            }
        }

        /* 规则四：暗模块占比偏离 50% */
        var dark = 0;
        for (i = 0; i < n * n; i++) { dark += mat[i]; }
        var pct = dark * 100 / (n * n);
        score += Math.floor(Math.abs(pct - 50) / 5) * 10;
        return score;
    }

    /* ---------------------------------------------------- 对外接口 */

    /*
     * encode(version, data, fixedMask) -> {n, mat}
     *   data 为 Uint8Array，长度不得超过该版本 ECC=L 字节容量。
     *   fixedMask 为 0-7 时跳过掩码评估直接使用该掩码（老设备快速路径，
     *   解码端对掩码无偏好，任一合法掩码均可读）；省略则八种全评估取最优。
     */
    function encode(version, data, fixedMask) {
        var dataCw = buildDataCodewords(version, data);
        var finalCw = buildFinalCodewords(version, dataCw);
        if (fixedMask >= 0 && fixedMask <= 7) {
            return buildMatrix(version, finalCw, fixedMask);
        }
        var best = null, bestScore = Infinity;
        for (var mask = 0; mask < 8; mask++) {
            var qr = buildMatrix(version, finalCw, mask);
            var s = penalty(qr);
            if (s < bestScore) { bestScore = s; best = qr; }
        }
        return best;
    }

    /* 字节模式容量（供上层断言用） */
    function capacity(version) {
        return DATA_CODEWORDS[version] - (version < 10 ? 2 : 3);
    }

    return {
        encode: encode,
        capacity: capacity,
        buildDataCodewords: buildDataCodewords,
        buildFinalCodewords: buildFinalCodewords,
        DATA_CODEWORDS: DATA_CODEWORDS,
        EC_PER_BLOCK: EC_PER_BLOCK,
        NUM_BLOCKS: NUM_BLOCKS
    };
}));
