/*
 * QrDrop Web 发送端 —— 应用层（原 index.html 内联脚本，纯 ES5）
 *
 * 依赖 VDP（vd-protocol.js）与 VDQR（vd-qr.js）两个全局。
 * 顶部即读取 DOM，故引入位置必须保持在 body 末尾。
 */
(function () {
    "use strict";

    /* 能力检测：老到没有 File API / 类型化数组的浏览器直接提示 */
    var errEl = document.getElementById("err");
    if (typeof Uint8Array === "undefined" || typeof FileReader === "undefined") {
        errEl.innerHTML = "此浏览器过旧：缺少 File API 或类型化数组（需要 IE10+ / Android 4+ / Safari 5.1+）";
        return;
    }

    var sess = null;          /* VDP.SendSession */
    var tiers = [];
    var tierIdx = 0;
    var nextBlockId = 0;      /* 已上屏游标：只在帧确认上屏后推进（对齐 PlaybackState 语义） */
    var framesShown = 0;
    var playing = false;
    var timer = null;         /* 降级路径的 setTimeout 句柄 */
    var canvas = document.getElementById("qrcanvas");
    var ctx = canvas.getContext("2d");

    var $ = function (id) { return document.getElementById(id); };

    /* rAF 与高精度计时的兼容取用；缺失则走 setTimeout 降级路径 */
    var raf = window.requestAnimationFrame || window.webkitRequestAnimationFrame ||
              window.mozRequestAnimationFrame || window.msRequestAnimationFrame || null;
    var caf = window.cancelAnimationFrame || window.webkitCancelAnimationFrame ||
              window.mozCancelAnimationFrame || window.msCancelAnimationFrame || null;
    var nowFn = (window.performance && window.performance.now) ?
                function () { return window.performance.now(); } :
                function () { return new Date().getTime(); };

    /* 早期 webkit/moz 的 rAF 有不传时间戳的实现，直接拿 ts 做差会得到 NaN
       并污染刷新率样本。统一在入口归一化，拿不到就用自己的时钟。 */
    function normTs(ts) {
        return (typeof ts === "number" && ts > 0) ? ts : nowFn();
    }

    /* ------------------------------------------------ 播放状态持久化 */

    function stateKey() { return "vdweb." + VDP.sessionIdHex(sess.sid); }

    function loadState() {
        try {
            var raw = window.localStorage.getItem(stateKey());
            if (!raw) { return; }
            var st = JSON.parse(raw);
            nextBlockId = st.nextBlockId % 4294967296 || 0;
            framesShown = st.framesShown || 0;
            if (st.tier >= 0 && st.tier < tiers.length) { tierIdx = st.tier; }
            if (st.targetFps > 0) { targetFps = st.targetFps; }
            else if (st.intervalMs >= 8) { targetFps = 1000 / st.intervalMs; }  /* 兼容旧存档 */
        } catch (e) { /* localStorage 不可用（如 file:// 下的老 IE）时静默跳过 */ }
    }

    function saveState() {
        try {
            window.localStorage.setItem(stateKey(), JSON.stringify({
                nextBlockId: nextBlockId,
                framesShown: framesShown,
                tier: tierIdx,
                targetFps: targetFps
            }));
        } catch (e) { /* 同上 */ }
    }

    /* ------------------------------------------------ 界面 */

    function fmtSize(n) {
        if (n < 1024) { return n + " B"; }
        if (n < 1048576) { return (n / 1024).toFixed(1) + " KB"; }
        return (n / 1048576).toFixed(2) + " MB";
    }

    /* 速度只有两个概念：帧率 fps，以及一帧占几个屏幕帧（hold）。
       毫秒不是可设项，只是由 hold 算出来的"这帧在屏上停了多久"，仅供显示。 */
    function showMs(h) { return h * vsyncMs; }
    function holdFps(h) { return 1000 / (h * vsyncMs); }
    function fmtFps(f) { return f.toFixed(f < 10 ? 1 : 0); }

    function currentPassFrames() {
        var m = tiers[tierIdx].m;
        var eps = sess.codec === VDP.CODEC_RLNC ? VDP.epsRlnc(sess.K) : VDP.epsLt(sess.K);
        return Math.ceil(Math.ceil(sess.K * (1 + eps)) / m);
    }

    function refreshStats() {
        if (!sess) { return; }
        var pass = currentPassFrames();
        $("stats").innerHTML = "已播帧数 " + framesShown +
            " ｜ 下一块序号 " + nextBlockId +
            " ｜ 当前档一轮约需 " + pass + " 帧（约 " +
            (pass / holdFps(hold)).toFixed(1) + " 秒）";
    }

    function refreshHealth() {
        if (!raf) {
            /* 无 rAF 就无从测刷新率，此时的帧率是 setTimeout 意义上的目标值，
               不能声称"每帧占几个屏幕帧"——那个数在这条路径上没有依据。 */
            $("health").innerHTML = "目标 " + fmtFps(holdFps(hold)) + " fps（每帧约 " +
                showMs(hold).toFixed(0) + " ms）｜ <span class='warn'>降级路径：本浏览器无 " +
                "requestAnimationFrame，测不到屏幕刷新率，帧边界不与刷新同步，" +
                "高帧率下可能产生撕裂帧</span>";
            return;
        }
        /* 速度只报一个数：实际帧率。毫秒作为派生读数附在后面。降速时才点出目标值。 */
        var txt = "实际 " + fmtFps(holdFps(hold)) + " fps" +
            " ｜ 每帧占 " + hold + " 个屏幕帧，停留 " + showMs(hold).toFixed(1) + " ms";
        txt += " ｜ 屏幕 " + (1000 / vsyncMs).toFixed(1) + " Hz" +
            (vsLocked ? "" : "<span class='warn'>（测定中，暂按 60Hz）</span>") +
            " ｜ 缓冲 " + ringCount() + "/" + (RING_SIZE - 1) +
            " ｜ 掉帧 " + missedTotal + " ｜ 缺帧等待 " + starveTotal;
        if (hold > baseHold) {
            txt += " <span class='warn'>已自动降速：设备产不出目标 " +
                fmtFps(holdFps(baseHold)) + " fps</span>";
        }
        if (stallTotal > 0) {
            txt += " <span class='warn'>页面被挂起过 " + stallTotal +
                " 次（切后台/锁屏会暂停播放，回到前台自动续上）</span>";
        }
        $("health").innerHTML = txt;
    }

    function fillTierSelect() {
        var sel = $("tier");
        sel.innerHTML = "";
        for (var i = 0; i < tiers.length; i++) {
            var t = tiers[i];
            var opt = document.createElement("option");
            opt.value = i;
            opt.text = "档" + (i + 1) + "  V" + t.version + "  每帧 " + t.m + " 块";
            sel.appendChild(opt);
        }
        sel.selectedIndex = tierIdx;
    }

    /* ------------------------------------------------ 布局（只在换档/缩放时做） */

    var MARGIN = 2;           /* 契约：margin 2 */
    var modN = 0;             /* 当前档模块数 */
    var modPx = 1;            /* 每模块像素 */
    var canvasSize = 300;

    function layout() {
        var t = tiers[tierIdx];
        var n = 17 + 4 * t.version;
        var avail = Math.min(
            (window.innerWidth || document.documentElement.clientWidth) - 40,
            (window.innerHeight || document.documentElement.clientHeight) - 60);
        if (avail < 100) { avail = 100; }
        var px = Math.floor(avail / (n + MARGIN * 2));
        if (px < 1) { px = 1; }
        var size = (n + MARGIN * 2) * px;
        modN = n;
        modPx = px;
        /* 只有尺寸真的变了才碰 canvas.width：赋值即重建后备缓冲并触发布局，
           放进播放循环会成为每帧的抖动源 */
        if (size !== canvasSize || canvas.width !== size) {
            canvasSize = size;
            canvas.width = size;
            canvas.height = size;
        }
        ringReset();
    }

    /* ------------------------------------------------ 帧环形缓冲（预渲染） */

    var RING_SIZE = 12;       /* 实际可用 RING_SIZE-1，留一格区分空与满 */
    var ring = [];            /* 每项 { cv, ct, blockId, m } */
    var ringHead = 0;         /* 下一个取出位置 */
    var ringTail = 0;         /* 下一个写入位置 */
    var fillBlockId = 0;      /* 预渲染填充游标，可跑在 nextBlockId 前面 */
    var fillSeq = 0;          /* 预渲染序号，仅用于快速掩码轮换 */

    function ringCount() {
        return (ringTail - ringHead + RING_SIZE) % RING_SIZE;
    }

    function ringReset() {
        ringHead = 0;
        ringTail = 0;
        /* 丢弃所有预渲染帧，填充游标回退到已上屏游标，保证 blockId 序列无空洞 */
        fillBlockId = nextBlockId;
        fillSeq = framesShown;
        for (var i = 0; i < RING_SIZE; i++) {
            if (!ring[i]) {
                ring[i] = { cv: document.createElement("canvas"), ct: null, blockId: 0, m: 0 };
                ring[i].ct = ring[i].cv.getContext("2d");
            }
            if (ring[i].cv.width !== canvasSize) {
                ring[i].cv.width = canvasSize;
                ring[i].cv.height = canvasSize;
            }
        }
    }

    /* 高帧率下八种掩码全评估太贵（每帧 8 次矩阵构建 + 罚分），
       会把预渲染本身变成掉帧源。解码端对掩码无偏好，故按帧轮换固定掩码。 */
    function fastMaskOn() {
        return $("fastmask").checked || hold <= 2;
    }

    /* 把一帧编码并光栅化进环形缓冲的下一个空位 */
    function fillOne() {
        var t = tiers[tierIdx];
        var slot = ring[ringTail];
        var frame = sess.encodeFrame(fillBlockId, t.m);
        var mask = fastMaskOn() ? (fillSeq & 7) : undefined;
        var qr = VDQR.encode(t.version, frame, mask);
        var n = qr.n;
        var g = slot.ct;
        var px = modPx;
        g.fillStyle = "#fff";
        g.fillRect(0, 0, canvasSize, canvasSize);
        g.fillStyle = "#000";
        /* 按行合并横向连续的黑模块，把 fillRect 调用数从 n*n 降到行程数量级 */
        for (var r = 0; r < n; r++) {
            var c = 0;
            while (c < n) {
                if (!qr.mat[r * n + c]) { c++; continue; }
                var s = c;
                while (c < n && qr.mat[r * n + c]) { c++; }
                g.fillRect((s + MARGIN) * px, (r + MARGIN) * px, (c - s) * px, px);
            }
        }
        slot.blockId = fillBlockId;
        slot.m = t.m;
        ringTail = (ringTail + 1) % RING_SIZE;
        fillBlockId = (fillBlockId + t.m) % 4294967296;
        fillSeq++;
    }

    /* 冷启动时同步填一批，避免开局就饥饿 */
    function prefill(n) {
        for (var i = 0; i < n && ringCount() < RING_SIZE - 1; i++) { fillOne(); }
    }

    /* ------------------------------------------------ 呈现与上屏确认 */

    var pending = null;       /* 已提交给合成器、等待下一次 rAF 确认上屏的帧 */

    /* 只做一次 blit。整条播放路径上唯一触碰主画布的地方。 */
    function present() {
        if (ringCount() === 0) { return false; }
        var slot = ring[ringHead];
        ctx.drawImage(slot.cv, 0, 0);
        ringHead = (ringHead + 1) % RING_SIZE;
        pending = slot;
        return true;
    }

    /* rAF 回调再次触发，说明上一次回调里的绘制已经过一个 vsync 合成上屏。
       游标在此刻推进，而不是 drawImage 返回时——后者只代表命令入队。
       pending 指向的槽在确认前不会被 fillOne 覆写：写入位置等于刚释放的槽时
       ringCount 必为 RING_SIZE-1，而填充判据要求严格小于该值，故被挡住。
       这条不变式依赖"环形缓冲永远空一格"的约定，改 RING_SIZE 判据时勿破坏。 */
    function commitPending() {
        if (!pending) { return; }
        nextBlockId = (pending.blockId + pending.m) % 4294967296;
        framesShown++;
        pending = null;
        if (framesShown % 120 === 0) { saveState(); }
    }

    /* ------------------------------------------------ vsync 测量与背压 */

    var vsyncMs = 16.7;
    var vsLocked = false;
    var vsSamples = [];
    var reSamples = [];       /* 锁定后的滚动样本，用于重新测量 */
    var hold = 3;             /* 每帧占用几个屏幕帧，整数保证帧边界对齐 vsync */
    var baseHold = 3;         /* 用户所选帧率对应的值，背压只在其之上加 */
    var targetFps = 20;       /* 用户意图，仅在刷新率变化时用于重新对齐 hold */
    var vsyncCount = 0;
    var lastTs = 0;
    var missedTotal = 0;
    var starveTotal = 0;
    var stallTotal = 0;       /* 标签页被挂起（切后台/锁屏）的次数 */
    var winTicks = 0;         /* 背压结算窗口 */
    var winMissed = 0;
    var winClean = 0;

    /* 帧率选项由实测刷新率派生：可达帧率只有 屏幕Hz/整数 这一族，
       填任意 ms 都会被 hold 量化，不如直接把量化后的结果摆出来给用户选。
       option.value 即 hold，选中项就是唯一的速度参数。 */
    function fillFpsSelect() {
        var sel = $("fps");
        var best = 1;
        var bestIdx = 0;
        var bestDiff = Infinity;
        var kept = 0;             /* 已入列的档数，同时是下一项的下标 */
        var prevFps = Infinity;   /* 上一个入列档的帧率，用于感知去重 */
        sel.innerHTML = "";
        /* 下界按帧率收敛到 5fps，而不是固定档数：高刷屏上 12 个屏幕帧才降到 12fps，
           按档数封顶会让 120/144Hz 设备反而调不慢，而慢档正是弱光远距扫描要用的。
           但整数分频在低端越来越密（144Hz 的尾部全是 5.x），差异小于 8% 的档直接跳过，
           否则高刷屏会得到一个二十多项、末尾几乎分辨不出区别的列表。 */
        for (var h = 1; h <= 40; h++) {
            var f = holdFps(h);
            if (f > prevFps * 0.92) { continue; }
            var opt = document.createElement("option");
            opt.value = h;
            opt.text = fmtFps(f) + (raf ? " fps（每帧 " + h + " 屏）"
                                        : " fps（每帧约 " + showMs(h).toFixed(0) + " ms）");
            sel.appendChild(opt);
            var d = Math.abs(f - targetFps);
            if (d < bestDiff) { bestDiff = d; best = h; bestIdx = kept; }
            prevFps = f;
            kept++;
            if (f <= 5) { break; }
        }
        sel.selectedIndex = bestIdx;
        baseHold = best;
        targetFps = holdFps(best);   /* 回写量化后的真实值，避免存档里留下达不到的数 */
        if (hold < baseHold) { hold = baseHold; }
    }

    /* 取样本的低分位而非最小值：最小值可能是一次异常短的回调。
       判据写成 !(dt > 0) 而不是 dt <= 0，NaN 参与比较恒为假，前者才能挡住它。 */
    function measureVsync(dt) {
        if (vsLocked || !(dt > 0) || dt > 100) { return; }
        vsSamples.push(dt);
        if (vsSamples.length < 20) { return; }
        vsSamples.sort(function (a, b) { return a - b; });
        vsyncMs = vsSamples[Math.floor(vsSamples.length * 0.25)];
        vsLocked = true;
        /* 刷新率测出来后选项才是真的，此处重建并把目标帧率对齐到最近的可达档 */
        fillFpsSelect();
        hold = baseHold;
    }

    /* 锁定后持续滚动复测：首批样本可能被启动抖动污染，
       窗口拖到另一块不同刷新率的显示器时也要跟着变。偏差超过 15% 才接受，
       避免正常抖动导致 hold 反复横跳。 */
    function remeasureVsync(dt) {
        if (!(dt > 0) || dt > 100) { return; }
        reSamples.push(dt);
        if (reSamples.length < 240) { return; }
        var s = reSamples.slice(0).sort(function (a, b) { return a - b; });
        var v = s[Math.floor(s.length * 0.25)];
        reSamples = [];
        if (Math.abs(v - vsyncMs) / vsyncMs > 0.15) {
            vsyncMs = v;
            fillFpsSelect();  /* 换了刷新率，可达帧率整族都变，选项跟着重建 */
            hold = baseHold;  /* 清掉旧刷新率下累积的背压 */
            winTicks = 0;
            winMissed = 0;
            winClean = 0;
        }
    }

    /* 刷新率是屏幕的属性，与是否在播放无关，所以不必等到按下播放才测。
       页面加载后跑一条只采样、不渲染的空转 rAF 探针，几百毫秒即可锁定，
       帧率选项一开始就是这块屏幕真实可达的值，不会先按 60Hz 猜一遍再跳变。 */
    function probeVsync() {
        if (!raf || vsLocked) { return; }
        var last = 0;
        var ticks = 0;
        var step = function (ts) {
            /* 播放循环自己会测，两条探针不必并存 */
            if (vsLocked || playing || ticks > 90) { return; }
            ticks++;
            var t = normTs(ts);
            if (last) { measureVsync(t - last); }
            last = t;
            raf(step);
            if (vsLocked && sess) { refreshHealth(); }
        };
        raf(step);
    }

    /* 掉帧说明设备产不出这个帧率。此时降速，而不是继续输出被合成器丢掉的半帧。 */
    function backoff(dt) {
        /* 切到后台时 rAF 整个停摆，回到前台的第一个 dt 可能是几秒。
           那是标签页挂起，不是渲染跟不上，不能据此降速。 */
        if (dt > vsyncMs * 8) { stallTotal++; reSamples = []; return; }
        remeasureVsync(dt);
        var lost = Math.round(dt / vsyncMs) - 1;
        if (lost > 0) { missedTotal += lost; winMissed += lost; }
        winTicks++;
        if (winTicks < 120) { return; }
        if (winMissed > 9 && $("autoslow").checked) {
            hold++;
            winClean = 0;
        } else if (winMissed === 0) {
            winClean++;
            if (winClean >= 2 && hold > baseHold) { hold--; winClean = 0; }
        }
        winTicks = 0;
        winMissed = 0;
    }

    /* ------------------------------------------------ 播放循环 */

    var rafId = null;
    var statTick = 0;

    function frameLoop(ts) {
        if (!playing) { return; }
        rafId = raf(frameLoop);
        var t0 = nowFn();

        commitPending();

        var ts2 = normTs(ts);
        if (lastTs) {
            var dt = ts2 - lastTs;
            if (!vsLocked) { measureVsync(dt); } else { backoff(dt); }
        }
        lastTs = ts2;

        vsyncCount++;
        if (vsyncCount >= hold) {
            if (present()) {
                vsyncCount = 0;
            } else {
                /* 缓冲空：保持当前帧继续显示。多显示几个周期的完整帧仍可读，
                   强行换上没准备好的内容才会产生废帧。 */
                starveTotal++;
            }
        }

        /* 本次回调的剩余预算内预渲染。超预算就不做，宁可缓冲变浅也不拖掉这一帧。 */
        if (ringCount() < RING_SIZE - 1 && (nowFn() - t0) < vsyncMs * 0.4) {
            try {
                fillOne();
            } catch (e) {
                stop();
                errEl.innerHTML = "编码出错: " + e.message;
                return;
            }
        }

        /* 统计刷新会触发布局，不能每帧做 */
        statTick++;
        if (statTick >= 30) {
            statTick = 0;
            refreshStats();
            refreshHealth();
        }
    }

    /* 无 rAF 的老浏览器降级路径：仍复用环形缓冲，把逐格绘制移出关键路径，
       但无法与刷新同步，高帧率下的撕裂无解，故在 refreshHealth 里明示。 */
    function tickLegacy() {
        if (!playing) { return; }
        var t0 = new Date().getTime();
        commitPending();
        try {
            if (ringCount() === 0) { fillOne(); }
            if (!present()) { starveTotal++; }
            if (ringCount() < RING_SIZE - 1) { fillOne(); }
        } catch (e) {
            stop();
            errEl.innerHTML = "编码出错: " + e.message;
            return;
        }
        statTick++;
        if (statTick >= 10) { statTick = 0; refreshStats(); refreshHealth(); }
        var wait = showMs(hold) - (new Date().getTime() - t0);
        if (wait < 0) { wait = 0; }
        timer = window.setTimeout(tickLegacy, wait);
    }

    function play() {
        if (!sess || playing) { return; }
        playing = true;
        $("btn_play").innerHTML = "暂停";
        $("qrwrap").style.display = "";
        layout();
        prefill(6);
        vsyncCount = hold;    /* 首帧立即上屏 */
        lastTs = 0;
        pending = null;
        if (raf) { rafId = raf(frameLoop); } else { tickLegacy(); }
    }

    function stop() {
        playing = false;
        $("btn_play").innerHTML = "开始播放";
        if (rafId && caf) { caf(rafId); }
        rafId = null;
        if (timer) { window.clearTimeout(timer); timer = null; }
        /* 未确认上屏的帧不计入游标：宁可重发一帧，也不跳过一帧 */
        pending = null;
        ringReset();
        saveState();
        refreshStats();
        refreshHealth();
    }

    /* ------------------------------------------------ 帧转储导出（契约 14） */

    function exportDump() {
        if (!sess) { return; }
        var t = tiers[tierIdx];
        var count = currentPassFrames();
        var parts = [];
        var total = 0;
        var base = 0;
        for (var f = 0; f < count; f++) {
            var frame = sess.encodeFrame(base, t.m);
            var rec = new Uint8Array(4 + frame.length);
            rec[0] = (frame.length >>> 24) & 0xFF;
            rec[1] = (frame.length >>> 16) & 0xFF;
            rec[2] = (frame.length >>> 8) & 0xFF;
            rec[3] = frame.length & 0xFF;
            rec.set(frame, 4);
            parts.push(rec);
            total += rec.length;
            base = (base + t.m) % 4294967296;
        }
        var all = new Uint8Array(total);
        var off = 0;
        for (var i = 0; i < parts.length; i++) { all.set(parts[i], off); off += parts[i].length; }
        var name = VDP.sessionIdHex(sess.sid) + ".vddump";
        try {
            var blob = new Blob([all], { type: "application/octet-stream" });
            if (window.navigator.msSaveBlob) {          /* IE10/11 */
                window.navigator.msSaveBlob(blob, name);
                return;
            }
            var a = document.createElement("a");
            a.href = (window.URL || window.webkitURL).createObjectURL(blob);
            a.download = name;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
        } catch (e) {
            errEl.innerHTML = "此浏览器不支持文件导出";
        }
    }

    /* ------------------------------------------------ 事件 */

    $("filepick").addEventListener("change", function () {
        var f = this.files && this.files[0];
        if (!f) { return; }
        stop();
        errEl.innerHTML = "";
        var reader = new FileReader();
        reader.onload = function () {
            try {
                var content = new Uint8Array(reader.result);
                sess = new VDP.SendSession(content, f.name);
            } catch (e) {
                errEl.innerHTML = "会话创建失败: " + e.message;
                return;
            }
            tiers = sess.tiers;
            tierIdx = 0;                  /* 默认档位：单个二维码容量最接近 2KB 的档 */
            var tierDiff = Infinity;
            for (var ti = 0; ti < tiers.length; ti++) {
                var d = Math.abs(tiers[ti].capacity - 2048);
                if (d < tierDiff) { tierDiff = d; tierIdx = ti; }
            }
            nextBlockId = 0;
            framesShown = 0;
            missedTotal = 0;
            starveTotal = 0;
            stallTotal = 0;
            loadState();          /* 同一文件同参数重传时续接游标 */
            fillTierSelect();
            fillFpsSelect();
            hold = baseHold;
            layout();
            $("i_file").innerHTML = sess.fileName;
            $("i_size").innerHTML = fmtSize(sess.contentLen) +
                "（流层 " + fmtSize(sess.stream.length) + "）";
            $("i_codec").innerHTML = sess.codec === VDP.CODEC_RLNC ? "解方程(RLNC)" : "剥洋葱(LT)";
            $("i_sid").innerHTML = VDP.sessionIdHex(sess.sid);
            $("i_T").innerHTML = sess.T;
            $("i_K").innerHTML = sess.K;
            $("sesspanel").style.display = "";
            refreshStats();
            refreshHealth();
        };
        reader.onerror = function () { errEl.innerHTML = "文件读取失败"; };
        reader.readAsArrayBuffer(f);
    });

    $("btn_play").addEventListener("click", function () {
        if (playing) { stop(); } else { play(); }
    });

    $("btn_reset").addEventListener("click", function () {
        nextBlockId = 0;
        framesShown = 0;
        ringReset();
        saveState();
        refreshStats();
    });

    $("btn_dump").addEventListener("click", exportDump);

    $("tier").addEventListener("change", function () {
        /* 换档只改 m：T/K/codec/sessionId 不变，游标继续推进（契约 9）。
           已预渲染的帧按旧档编码，必须整体丢弃，layout 内的 ringReset 负责回退填充游标。 */
        tierIdx = this.selectedIndex;
        if (sess) { layout(); prefill(playing ? 4 : 0); }
        saveState();
        refreshStats();
        refreshHealth();
    });

    $("fps").addEventListener("change", function () {
        baseHold = parseInt(this.value, 10) || 1;
        targetFps = holdFps(baseHold);
        hold = baseHold;      /* 手动改帧率时清掉背压累积的降速 */
        saveState();
        refreshStats();
        refreshHealth();
    });

    $("fastmask").addEventListener("change", function () {
        if (sess) { ringReset(); prefill(playing ? 4 : 0); }
    });

    /* 缩放会改变模块像素，必须重建缓冲；防抖避免拖动过程中反复重建 */
    var resizeTimer = null;
    window.addEventListener("resize", function () {
        if (!sess) { return; }
        if (resizeTimer) { window.clearTimeout(resizeTimer); }
        resizeTimer = window.setTimeout(function () {
            resizeTimer = null;
            layout();
            prefill(playing ? 4 : 0);
            /* 窗口被拖到另一块刷新率不同的显示器上时也会触发 resize。
               播放中由 remeasureVsync 负责，空闲时这里重开探针。 */
            if (!playing) { vsLocked = false; vsSamples = []; probeVsync(); }
        }, 200);
    });

    probeVsync();     /* 先把这块屏幕的刷新率测出来，再谈可选帧率 */
})();
