/*
 * VisionDrop 协议 v1 —— Web 发送端协议层（纯 ES5，无任何依赖）
 *
 * 语义与 protocol/CONTRACT.md、protocol/refimpl.py 逐位一致，
 * 验收方式是 test/run-vectors.js 对 protocol/vectors/ 的全量比对。
 *
 * 兼容性：只用 ES5 语法 + Uint8Array（IE10+ / Android 4+ / Safari 5.1+）。
 * 不使用 Promise / crypto.subtle / TextEncoder / BigInt。
 */
(function (root, factory) {
    if (typeof module === "object" && module.exports) {
        module.exports = factory();
    } else {
        root.VDP = factory();
    }
}(typeof self !== "undefined" ? self : this, function () {
    "use strict";

    /* Math.imul 兜底（IE 没有）：手工拆半字做模 2^32 乘法 */
    var imul = Math.imul || function (a, b) {
        var ah = (a >>> 16) & 0xFFFF, al = a & 0xFFFF;
        var bh = (b >>> 16) & 0xFFFF, bl = b & 0xFFFF;
        return ((al * bl) + (((ah * bl + al * bh) << 16) >>> 0)) | 0;
    };

    var POW32 = 4294967296;

    /* ------------------------------------------------------------ 常量 */

    /* QR 版本 -> ECC=L 字节模式载荷容量，与 refimpl.py 的 QR_CAPACITY 同表 */
    var QR_CAPACITY = [0,
        17, 32, 53, 78, 106, 134, 154, 192, 230, 271,
        321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
        929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732,
        1840, 1952, 2068, 2188, 2303, 2431, 2563, 2699, 2809, 2953];

    var MAX_CAPACITY = QR_CAPACITY[40];
    var FRAME_HEADER_LEN = 20;
    var MIN_TIER_CAPACITY = 512;
    var MAX_TIERS = 10;
    var FRAME_MAGIC = 0x56;
    var PROTOCOL_VERSION = 1;
    var CODEC_RLNC = 0, CODEC_LT = 1;
    var T_MIN = 16, T_MAX = 500, K_MAX_RLNC = 2720, T_MIN_LT = 293;
    var LT_C = 0.03, LT_DELTA = 0.05, LN_GRID = 65536.0;

    /* ------------------------------------------------------------ PRNG */

    function mix32(x) {
        x = x >>> 0;
        x ^= x >>> 16;
        x = imul(x, 0x7FEB352D) >>> 0;
        x ^= x >>> 15;
        x = imul(x, 0x846CA68B) >>> 0;
        x ^= x >>> 16;
        return x >>> 0;
    }

    function xorshift32(s) {
        s = s >>> 0;
        s = (s ^ (s << 13)) >>> 0;
        s = (s ^ (s >>> 17)) >>> 0;
        s = (s ^ (s << 5)) >>> 0;
        return s >>> 0;
    }

    /* ------------------------------------------------------------ SHA-256 */

    var SHA_K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];

    /* 输入 Uint8Array，输出 32 字节 Uint8Array */
    function sha256(data) {
        var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a,
            h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
        var len = data.length;
        var totalLen = len + 9;
        var padLen = (totalLen % 64 === 0) ? totalLen : (Math.floor(totalLen / 64) + 1) * 64;
        var msg = new Uint8Array(padLen);
        msg.set(data);
        msg[len] = 0x80;
        /* 位长度写在末尾 8 字节大端；len < 2^53，高位用除法拆 */
        var bitLenHi = Math.floor(len / 536870912);       /* len*8 / 2^32 */
        var bitLenLo = (len * 8) % POW32;
        msg[padLen - 8] = (bitLenHi >>> 24) & 0xFF;
        msg[padLen - 7] = (bitLenHi >>> 16) & 0xFF;
        msg[padLen - 6] = (bitLenHi >>> 8) & 0xFF;
        msg[padLen - 5] = bitLenHi & 0xFF;
        msg[padLen - 4] = (bitLenLo >>> 24) & 0xFF;
        msg[padLen - 3] = (bitLenLo >>> 16) & 0xFF;
        msg[padLen - 2] = (bitLenLo >>> 8) & 0xFF;
        msg[padLen - 1] = bitLenLo & 0xFF;

        var w = new Array(64);
        for (var off = 0; off < padLen; off += 64) {
            var i;
            for (i = 0; i < 16; i++) {
                var p = off + i * 4;
                w[i] = ((msg[p] << 24) | (msg[p + 1] << 16) | (msg[p + 2] << 8) | msg[p + 3]) | 0;
            }
            for (i = 16; i < 64; i++) {
                var x = w[i - 15], y = w[i - 2];
                var s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
                var s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
                w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7;
            for (i = 0; i < 64; i++) {
                var S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
                var ch = (e & f) ^ (~e & g);
                var t1 = (hh + S1 + ch + SHA_K[i] + w[i]) | 0;
                var S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
                var maj = (a & b) ^ (a & c) ^ (b & c);
                var t2 = (S0 + maj) | 0;
                hh = g; g = f; f = e; e = (d + t1) | 0;
                d = c; c = b; b = a; a = (t1 + t2) | 0;
            }
            h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0;
            h4 = (h4 + e) | 0; h5 = (h5 + f) | 0; h6 = (h6 + g) | 0; h7 = (h7 + hh) | 0;
        }
        var out = new Uint8Array(32);
        var hs = [h0, h1, h2, h3, h4, h5, h6, h7];
        for (var j = 0; j < 8; j++) {
            out[j * 4] = (hs[j] >>> 24) & 0xFF;
            out[j * 4 + 1] = (hs[j] >>> 16) & 0xFF;
            out[j * 4 + 2] = (hs[j] >>> 8) & 0xFF;
            out[j * 4 + 3] = hs[j] & 0xFF;
        }
        return out;
    }

    /* ------------------------------------------------------------ CRC32 */

    var CRC_TABLE = (function () {
        var t = new Array(256);
        for (var n = 0; n < 256; n++) {
            var c = n;
            for (var k = 0; k < 8; k++) {
                c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
            }
            t[n] = c >>> 0;
        }
        return t;
    })();

    function crc32(buf, start, end) {
        start = start || 0;
        if (end === undefined) { end = buf.length; }
        var c = 0xFFFFFFFF;
        for (var i = start; i < end; i++) {
            c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
        }
        return (c ^ 0xFFFFFFFF) >>> 0;
    }

    /* ------------------------------------------------ LT：量化 CDF 与邻居 */

    /* 量化对数：把跨平台 ln 的 ulp 差异挡在 2^-16 网格之外（契约 4.1） */
    function lnq(x) {
        return Math.floor(Math.log(x) * LN_GRID + 0.5) / LN_GRID;
    }

    /* Robust Soliton 量化 CDF，返回长度 K+1 的普通数组（值可达 2^32，用 double 承载） */
    function rsCdfQ(K) {
        var rho = new Array(K + 2), tau = new Array(K + 2);
        var d;
        for (d = 0; d <= K + 1; d++) { rho[d] = 0.0; tau[d] = 0.0; }
        rho[1] = 1.0 / K;
        for (d = 2; d <= K; d++) { rho[d] = 1.0 / (d * (d - 1)); }

        var R = LT_C * lnq(K / LT_DELTA) * Math.sqrt(K);
        var kr = Math.max(1, Math.floor(K / R));
        var lim = Math.min(kr, K + 1);
        for (d = 1; d < lim; d++) { tau[d] = R / (d * K); }
        if (kr <= K) { tau[kr] = Math.max(0.0, R * lnq(R / LT_DELTA) / K); }

        var Z = 0.0;
        for (d = 1; d <= K; d++) { Z += rho[d] + tau[d]; }

        var cdf = new Array(K + 1);
        cdf[0] = 0;
        var acc = 0.0;
        for (d = 1; d <= K; d++) {
            acc += (rho[d] + tau[d]) / Z;
            var q = Math.floor(acc * POW32);
            if (q > POW32) { q = POW32; }
            cdf[d] = q;
        }
        cdf[K] = POW32;
        return cdf;
    }

    /* 返回 [度数 d, 推进后的 state] */
    function ltSampleDegree(state, K, cdf) {
        state = xorshift32(state);
        var r = state;
        var lo = 1, hi = K;
        while (lo < hi) {
            var mid = (lo + hi) >> 1;
            if (cdf[mid] <= r) { lo = mid + 1; } else { hi = mid; }
        }
        return [lo, state];
    }

    /* blockId -> 升序源块索引数组 */
    function ltNeighbors(blockId, K, cdf) {
        var state = mix32(blockId);
        var t = ltSampleDegree(state, K, cdf);
        var d = t[0];
        state = t[1];
        if (d > K) { d = K; }
        var picked = {};
        var count = 0;
        /* 拒绝采样：取模有偏但两端一致（契约 4.3） */
        while (count < d) {
            state = xorshift32(state);
            var idx = state % K;
            if (!picked[idx]) { picked[idx] = true; count++; }
        }
        var out = [];
        for (var key in picked) {
            if (picked.hasOwnProperty(key)) { out.push(parseInt(key, 10)); }
        }
        out.sort(function (a, b) { return a - b; });
        return out;
    }

    /* ------------------------------------------------ RLNC：系数向量 */

    /* blockId -> 系数位集，返回 Uint8Array（小端：字节 j 的第 b 位 = 源块 8j+b） */
    function rlncCoeffBytes(blockId, K) {
        var nbytes = (K + 7) >> 3;
        var out = new Uint8Array(nbytes);
        var base = mix32(blockId);
        var words = (K + 31) >> 5;
        var allZero = true;
        for (var i = 0; i < words; i++) {
            var word = mix32((base ^ (imul(i, 0x9E3779B9) >>> 0)) >>> 0);
            for (var b = 0; b < 4; b++) {
                var pos = i * 4 + b;
                if (pos < nbytes) { out[pos] = (word >>> (b * 8)) & 0xFF; }
            }
        }
        /* 截断到 K 位 */
        if ((K & 7) !== 0) { out[nbytes - 1] &= (1 << (K & 7)) - 1; }
        for (var j = 0; j < nbytes; j++) {
            if (out[j] !== 0) { allZero = false; break; }
        }
        /* 全零兜底：强制置位 blockId mod K（契约 3.1） */
        if (allZero) {
            var p = blockId % K;
            out[p >> 3] |= 1 << (p & 7);
        }
        return out;
    }

    function rlncNeighbors(blockId, K) {
        var bits = rlncCoeffBytes(blockId, K);
        var out = [];
        for (var i = 0; i < K; i++) {
            if (bits[i >> 3] & (1 << (i & 7))) { out.push(i); }
        }
        return out;
    }

    /* ------------------------------------------------------------ 选参 */

    function epsRlnc(K) { return K <= 1 ? 0.0 : 2.0 / K; }
    function epsLt(K) { return K <= 1 ? 0.0 : 1.85 / Math.pow(K, 0.37); }

    /* 返回 {codec, T, K, m, frames}；并列取舍：帧数 -> T 最小 -> 解方程优先 */
    function pickParams(streamLen) {
        var best = null;
        for (var T = T_MIN; T <= T_MAX; T++) {
            var K = Math.max(1, Math.ceil(streamLen / T));
            var m = Math.floor((MAX_CAPACITY - FRAME_HEADER_LEN) / T);
            if (m < 1) { continue; }
            var frames, cand;
            if (K <= K_MAX_RLNC && K <= 8 * T) {
                frames = Math.ceil(Math.ceil(K * (1 + epsRlnc(K))) / m);
                cand = [frames, T, CODEC_RLNC, K, m];
                if (best === null || candLess(cand, best)) { best = cand; }
            }
            if (T >= T_MIN_LT) {
                frames = Math.ceil(Math.ceil(K * (1 + epsLt(K))) / m);
                cand = [frames, T, CODEC_LT, K, m];
                if (best === null || candLess(cand, best)) { best = cand; }
            }
        }
        return { codec: best[2], T: best[1], K: best[3], m: best[4], frames: best[0] };
    }

    function candLess(a, b) {
        for (var i = 0; i < a.length; i++) {
            if (a[i] < b[i]) { return true; }
            if (a[i] > b[i]) { return false; }
        }
        return false;
    }

    /* ------------------------------------------------------------ 档位 */

    /* 返回 [{version, capacity, m}, ...]，m 升序，至多 10 档（契约 9） */
    function buildTiers(T) {
        var need = Math.max(MIN_TIER_CAPACITY, FRAME_HEADER_LEN + T);
        var byM = {};
        var order = [];
        for (var v = 1; v <= 40; v++) {
            var p = QR_CAPACITY[v];
            if (p < need) { continue; }
            var m = Math.floor((p - FRAME_HEADER_LEN) / T);
            if (m < 1) { continue; }
            if (byM[m] === undefined) { byM[m] = v; order.push(m); }
        }
        order.sort(function (a, b) { return a - b; });
        var tiers = [];
        for (var i = 0; i < order.length; i++) {
            var mm = order[i];
            tiers.push({ version: byM[mm], capacity: QR_CAPACITY[byM[mm]], m: mm });
        }
        if (tiers.length <= MAX_TIERS) { return tiers; }
        /* 超过 10 档：按 m 的对数等比抽取，首尾必取，被挤掉的名额从尾部回填 */
        var lo = tiers[0].m, hi = tiers[tiers.length - 1].m;
        var chosen = [];
        function inChosen(x) {
            for (var q = 0; q < chosen.length; q++) { if (chosen[q] === x) { return true; } }
            return false;
        }
        for (var j = 0; j < MAX_TIERS; j++) {
            var target = lo * Math.pow(hi / lo, j / (MAX_TIERS - 1));
            var idx = 0;
            while (idx < tiers.length && tiers[idx].m < target) { idx++; }
            if (idx >= tiers.length) { idx = tiers.length - 1; }
            while (inChosen(idx)) { idx++; }
            if (idx < tiers.length) { chosen.push(idx); }
        }
        var k = tiers.length - 1;
        while (chosen.length < MAX_TIERS && k >= 0) {
            if (!inChosen(k)) { chosen.push(k); }
            k--;
        }
        chosen.sort(function (a, b) { return a - b; });
        var out = [];
        for (var c = 0; c < chosen.length; c++) { out.push(tiers[chosen[c]]); }
        return out;
    }

    /* ------------------------------------------------------------ 流层 */

    /* 字符串 -> UTF-8 字节（老浏览器没有 TextEncoder） */
    function utf8Bytes(str) {
        var s = unescape(encodeURIComponent(str));
        var out = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) { out[i] = s.charCodeAt(i) & 0xFF; }
        return out;
    }

    function writeU32BE(buf, off, v) {
        buf[off] = (v >>> 24) & 0xFF;
        buf[off + 1] = (v >>> 16) & 0xFF;
        buf[off + 2] = (v >>> 8) & 0xFF;
        buf[off + 3] = v & 0xFF;
    }

    function writeU64BE(buf, off, v) {
        /* 文件不可能超过 2^53，高 32 位用除法拆 */
        writeU32BE(buf, off, Math.floor(v / POW32));
        writeU32BE(buf, off + 4, v % POW32);
    }

    /*
     * 构造流层字节。Web 端不做 deflate（老浏览器无原生压缩接口，纯 JS 实现
     * 体积与风险都不划算），恒为不压缩，flags bit0 = 0——契约允许：压缩是
     * 自适应可选项，接收端按 flag 处理。
     * 返回 {stream: Uint8Array, contentSha: Uint8Array(32), compressed: false}
     */
    function buildStream(content, fileName) {
        var digest = sha256(content);
        var fn = utf8Bytes(fileName);
        var hdrLen = 54 + fn.length;
        var stream = new Uint8Array(hdrLen + content.length);
        stream[0] = 0x56;                 /* 'V' */
        stream[1] = 0x44;                 /* 'D' */
        stream[2] = 1;                    /* 流格式版本 */
        stream[3] = 0;                    /* flags：不压缩 */
        writeU64BE(stream, 4, content.length);
        writeU64BE(stream, 12, content.length);
        stream.set(digest, 20);
        stream[52] = (fn.length >>> 8) & 0xFF;
        stream[53] = fn.length & 0xFF;
        stream.set(fn, 54);
        stream.set(content, hdrLen);
        return { stream: stream, contentSha: digest, compressed: false };
    }

    /* ------------------------------------------------------------ 会话 */

    /* sessionId = SHA256(sha256 ‖ T(2B) ‖ K(3B) ‖ codec(1B)) 前 4 字节大端 */
    function sessionId(contentSha, T, K, codec) {
        var buf = new Uint8Array(38);
        buf.set(contentSha, 0);
        buf[32] = (T >>> 8) & 0xFF;
        buf[33] = T & 0xFF;
        buf[34] = (K >>> 16) & 0xFF;
        buf[35] = (K >>> 8) & 0xFF;
        buf[36] = K & 0xFF;
        buf[37] = codec & 0xFF;
        var d = sha256(buf);
        return ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) >>> 0;
    }

    function sessionIdHex(sid) {
        var s = (sid >>> 0).toString(16);
        while (s.length < 8) { s = "0" + s; }
        return s;
    }

    /* ------------------------------------------------------------ 帧层 */

    /*
     * 发送会话：持有源块与编码状态。
     *   content  文件内容 Uint8Array
     *   fileName 文件名
     */
    function SendSession(content, fileName) {
        var st = buildStream(content, fileName);
        var p = pickParams(st.stream.length);
        this.fileName = fileName;
        this.contentLen = content.length;
        this.stream = st.stream;
        this.contentSha = st.contentSha;
        this.compressed = st.compressed;
        this.codec = p.codec;
        this.T = p.T;
        this.K = p.K;
        this.framesPerPass = p.frames;
        this.sid = sessionId(st.contentSha, p.T, p.K, p.codec);
        this.tiers = buildTiers(p.T);
        this.cdf = p.codec === CODEC_LT ? rsCdfQ(p.K) : null;
        /* 源块拼进一整块补零缓冲，第 i 块 = padded[i*T, (i+1)*T) */
        this.padded = new Uint8Array(p.K * p.T);
        this.padded.set(st.stream);
    }

    SendSession.prototype.neighborsOf = function (blockId) {
        if (this.codec === CODEC_RLNC) { return rlncNeighbors(blockId, this.K); }
        return ltNeighbors(blockId, this.K, this.cdf);
    };

    /* 编码块载荷：邻居源块逐字节异或，写入 out 的 outOff 起 T 字节 */
    SendSession.prototype.encodeBlockInto = function (blockId, out, outOff) {
        var T = this.T;
        var nb = this.neighborsOf(blockId);
        var i, j;
        for (j = 0; j < T; j++) { out[outOff + j] = 0; }
        for (i = 0; i < nb.length; i++) {
            var src = nb[i] * T;
            for (j = 0; j < T; j++) { out[outOff + j] ^= this.padded[src + j]; }
        }
    };

    /* 产出完整一帧：baseBlockId 起 m 个编码块（契约 8） */
    SendSession.prototype.encodeFrame = function (baseBlockId, m) {
        var T = this.T;
        var frame = new Uint8Array(FRAME_HEADER_LEN + m * T);
        for (var i = 0; i < m; i++) {
            var bid = (baseBlockId + i) % POW32;
            this.encodeBlockInto(bid, frame, FRAME_HEADER_LEN + i * T);
        }
        frame[0] = FRAME_MAGIC;
        frame[1] = ((PROTOCOL_VERSION << 4) | ((this.compressed ? 1 : 0) << 3) | (this.codec << 2)) & 0xFF;
        writeU32BE(frame, 2, this.sid);
        frame[6] = (this.K >>> 16) & 0xFF;
        frame[7] = (this.K >>> 8) & 0xFF;
        frame[8] = this.K & 0xFF;
        frame[9] = (T >>> 8) & 0xFF;
        frame[10] = T & 0xFF;
        frame[11] = m & 0xFF;
        writeU32BE(frame, 12, baseBlockId % POW32);
        writeU32BE(frame, 16, crc32(frame, FRAME_HEADER_LEN, frame.length));
        return frame;
    };

    /* ------------------------------------------------------------ 导出 */

    return {
        QR_CAPACITY: QR_CAPACITY,
        FRAME_HEADER_LEN: FRAME_HEADER_LEN,
        CODEC_RLNC: CODEC_RLNC,
        CODEC_LT: CODEC_LT,
        mix32: mix32,
        xorshift32: xorshift32,
        sha256: sha256,
        crc32: crc32,
        rsCdfQ: rsCdfQ,
        ltSampleDegree: ltSampleDegree,
        ltNeighbors: ltNeighbors,
        rlncCoeffBytes: rlncCoeffBytes,
        rlncNeighbors: rlncNeighbors,
        epsRlnc: epsRlnc,
        epsLt: epsLt,
        pickParams: pickParams,
        buildTiers: buildTiers,
        utf8Bytes: utf8Bytes,
        buildStream: buildStream,
        sessionId: sessionId,
        sessionIdHex: sessionIdHex,
        SendSession: SendSession
    };
}));
