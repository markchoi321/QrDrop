#!/usr/bin/env node
/*
 * Web 发送端跨语言向量测试：用 Node 加载 vd-protocol.js / vd-qr.js，
 * 逐位比对 protocol/vectors/ 下的全部测试向量，并导出帧转储供
 * protocol/crosscheck.py 做端到端还原校验（契约 14）。
 *
 * 运行：node sender/web/test/run-vectors.js
 */
"use strict";

var fs = require("fs");
var path = require("path");

var VDP = require("../vd-protocol.js");
var VDQR = require("../vd-qr.js");

var VEC = path.join(__dirname, "..", "..", "..", "protocol", "vectors");
var failures = 0, checks = 0;

function ok(cond, msg) {
    checks++;
    if (!cond) {
        failures++;
        console.log("失败: " + msg);
    }
}

function lines(name) {
    return fs.readFileSync(path.join(VEC, name), "utf8").split("\n")
        .filter(function (l) { return l.length > 0 && l.charAt(0) !== "#"; });
}

function hex(u8) {
    var s = "";
    for (var i = 0; i < u8.length; i++) {
        s += (u8[i] < 16 ? "0" : "") + u8[i].toString(16);
    }
    return s;
}

/* ---------------------------------------------------------- 1. PRNG */
lines("prng.txt").forEach(function (l) {
    var p = l.split(" ");
    var input = parseInt(p[1], 16) >>> 0;
    var expect = parseInt(p[2], 16) >>> 0;
    var got = p[0] === "mix32" ? VDP.mix32(input) : VDP.xorshift32(input);
    ok(got === expect, "prng " + l + " 实得 " + got.toString(16));
});
console.log("prng.txt 通过");

/* ---------------------------------------------------------- 2. CDF */
var cdfCache = {};
function cdfOf(K) {
    if (!cdfCache[K]) { cdfCache[K] = VDP.rsCdfQ(K); }
    return cdfCache[K];
}
lines("rs_cdf.txt").forEach(function (l) {
    var p = l.split(" ");
    var K = +p[0], d = +p[1], expect = +p[2];
    ok(cdfOf(K)[d] === expect, "rs_cdf K=" + K + " d=" + d +
        " 期望 " + expect + " 实得 " + cdfOf(K)[d]);
});
console.log("rs_cdf.txt 通过");

/* ---------------------------------------------------------- 3. LT 邻居 */
lines("lt_neighbors.txt").forEach(function (l) {
    var p = l.split(" ");
    var K = +p[0], bid = +p[1], deg = +p[2];
    var nb = VDP.ltNeighbors(bid >>> 0, K, cdfOf(K));
    ok(nb.length === deg && nb.join(",") === p[3],
        "lt_neighbors K=" + K + " bid=" + bid + " 实得 " + nb.join(","));
});
console.log("lt_neighbors.txt 通过");

/* ---------------------------------------------------------- 4. RLNC 系数 */
lines("rlnc_coeff.txt").forEach(function (l) {
    var p = l.split(" ");
    var K = +p[0], bid = +p[1];
    var got = hex(VDP.rlncCoeffBytes(bid >>> 0, K));
    ok(got === p[2], "rlnc_coeff K=" + K + " bid=" + bid + " 实得 " + got);
});
console.log("rlnc_coeff.txt 通过");

/* ---------------------------------------------------------- 5. 选参 */
lines("params.txt").forEach(function (l) {
    var p = l.split(" ").map(Number);
    var r = VDP.pickParams(p[0]);
    ok(r.codec === p[1] && r.T === p[2] && r.K === p[3] && r.m === p[4] && r.frames === p[5],
        "params streamLen=" + p[0] + " 实得 codec=" + r.codec + " T=" + r.T +
        " K=" + r.K + " m=" + r.m + " frames=" + r.frames);
});
console.log("params.txt 通过");

/* ---------------------------------------------------------- 6. 档位 */
var tierRows = {};
lines("tiers.txt").forEach(function (l) {
    var p = l.split(" ").map(Number);
    if (!tierRows[p[0]]) { tierRows[p[0]] = []; }
    tierRows[p[0]].push(p);
});
Object.keys(tierRows).forEach(function (T) {
    var tiers = VDP.buildTiers(+T);
    var rows = tierRows[T];
    ok(tiers.length === rows.length, "tiers T=" + T + " 档数 " + tiers.length);
    rows.forEach(function (p, i) {
        var t = tiers[i];
        ok(t && t.version === p[2] && t.capacity === p[3] && t.m === p[4],
            "tiers T=" + T + " 档" + p[1] + " 实得 V" + (t && t.version) + " m=" + (t && t.m));
    });
});
console.log("tiers.txt 通过");

/* ---------------------------------------------------------- 7. 流层 + 会话 + 帧 */
var fixture = new Uint8Array(fs.readFileSync(path.join(VEC, "fixture.bin")));
var streamExpect = new Uint8Array(fs.readFileSync(path.join(VEC, "stream.bin")));
var e2e = {};
lines("e2e.txt").forEach(function (l) {
    var i = l.indexOf(" ");
    e2e[l.slice(0, i)] = l.slice(i + 1);
});

ok(hex(VDP.sha256(fixture)) === e2e.contentSha256, "fixture sha256");

var st = VDP.buildStream(fixture, e2e.fileName);
ok(hex(st.stream) === hex(streamExpect), "流层字节与 stream.bin 一致");
ok(hex(VDP.sha256(st.stream)) === e2e.streamSha256, "流层 sha256");

/* 复用 SendSession 的帧编码路径，手工覆盖两种 codec 的参数 */
function frameVectors(codecName, codec) {
    var T = +e2e[codecName + ".T"], K = +e2e[codecName + ".K"], m = +e2e[codecName + ".m"];
    var sidExpect = parseInt(e2e[codecName + ".sessionId"], 16) >>> 0;
    var sid = VDP.sessionId(st.contentSha, T, K, codec);
    ok(sid === sidExpect, codecName + " sessionId 实得 " + VDP.sessionIdHex(sid));

    /* 构造一个会话对象并覆盖参数（选参对 rlnc 会得到同一组值，lt 是固定值） */
    var sess = new VDP.SendSession(fixture, e2e.fileName);
    sess.codec = codec;
    sess.T = T; sess.K = K; sess.sid = sid;
    sess.cdf = codec === VDP.CODEC_LT ? VDP.rsCdfQ(K) : null;
    sess.padded = new Uint8Array(K * T);
    sess.padded.set(st.stream);

    lines("frames_" + codecName + ".txt").forEach(function (l) {
        var i = l.indexOf(" ");
        var base = +l.slice(0, i);
        var frame = sess.encodeFrame(base >>> 0, m);
        ok(hex(frame) === l.slice(i + 1), codecName + " 帧 base=" + base);
    });
    console.log("frames_" + codecName + ".txt 通过");
    return sess;
}
frameVectors("rlnc", VDP.CODEC_RLNC);
var sessLt = frameVectors("lt", VDP.CODEC_LT);

/* rlnc 参数应与选参算法一致（e2e 固定 T 取的就是选参真实结果） */
var picked = VDP.pickParams(st.stream.length);
ok(picked.codec === VDP.CODEC_RLNC && picked.T === +e2e["rlnc.T"] &&
    picked.K === +e2e["rlnc.K"], "fixture 选参与 e2e 一致");

/* ---------------------------------------------------------- 8. QR 数据码字 */
lines("qr_codewords.txt").forEach(function (l) {
    var p = l.split(" ");
    var version = +p[0];
    var frameBytes = new Uint8Array(p[1].length / 2);
    for (var i = 0; i < frameBytes.length; i++) {
        frameBytes[i] = parseInt(p[1].substr(i * 2, 2), 16);
    }
    var got = hex(VDQR.buildDataCodewords(version, frameBytes));
    ok(got === p[2], "qr_codewords V" + version + "\n期望 " + p[2] + "\n实得 " + got);
});
console.log("qr_codewords.txt 通过");

/* ---------------------------------------------------------- 9. QR 结构自检 */
/* 每个版本编码一次，校验矩阵尺寸与总码字数 */
for (var v = 1; v <= 40; v++) {
    var cap = VDQR.capacity(v);
    ok(cap === VDP.QR_CAPACITY[v], "V" + v + " 容量表一致");
    var data = new Uint8Array(cap);
    for (var i = 0; i < cap; i++) { data[i] = (i * 7 + v) & 0xFF; }
    var qr = VDQR.encode(v, data, v % 8);
    ok(qr.n === 17 + 4 * v, "V" + v + " 模块数");
}
console.log("QR 全版本结构自检通过");

/* ---------------------------------------------------------- 10. 帧转储 */
/* 契约 14：导出 [4B 大端长度][帧字节] 记录流，交给 crosscheck.py 端到端还原 */
var dumpPath = process.argv[2] || path.join(require("os").tmpdir(), "vd_web_dump.bin");
var parts = [];
var m = +e2e["lt.m"];
var total = Math.ceil(+e2e["lt.K"] * 2.5 / m);      /* 冗余 2.5 倍，够 30% 丢帧 */
for (var f = 0; f < total; f++) {
    var frame = sessLt.encodeFrame((f * m) >>> 0, m);
    var lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32BE(frame.length, 0);
    parts.push(lenBuf, Buffer.from(frame));
}
fs.writeFileSync(dumpPath, Buffer.concat(parts));
console.log("帧转储已写入 " + dumpPath + "（" + total + " 帧，LT 编码）");

console.log("\n共 " + checks + " 项检查，失败 " + failures + " 项");
process.exit(failures === 0 ? 0 : 1);
