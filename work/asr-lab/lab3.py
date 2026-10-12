import sys, json, re, glob, os, time
import numpy as np
exec(open("lab2.py").read().split("# ---------------- strategies")[0])
from lab2_score import edits

def windows(segs, cap_s):
    """Group consecutive segments into decode windows of at most cap_s seconds."""
    groups, cur = [], []
    for seg in segs:
        if cur and (seg[1]-cur[0][0])/SR > cap_s: groups.append(cur); cur = []
        cur.append(seg)
    if cur: groups.append(cur)
    return [(g[0][0], g[-1][1]) for g in groups]

def squeeze(a, keep_ms=80):
    """Shorten every pause to keep_ms: a fast talker with almost no gaps."""
    f = 320; rms = np.array([np.sqrt(np.mean(a[i:i+f]**2)) for i in range(0, len(a)-f+1, f)])
    out, run = [], 0
    for k, r in enumerate(rms):
        if r < 0.003:
            run += 1
            if run*20 > keep_ms: continue
        else: run = 0
        out.append(a[k*f:(k+1)*f])
    return np.concatenate(out)

clips = sorted(glob.glob("corpus/t*-*.wav"))
rng = np.random.default_rng(11)
def noisy(a):
    n = np.convolve(rng.normal(0, 1, len(a)), np.ones(8)/8, mode="same").astype(np.float32)
    return a + n*(0.006/np.sqrt(np.mean(n**2)))

PLANS = [("A 现状 4s 硬切", None), ("B 停顿处切（单遍）", 0), ("W12 合成 ≤12s 窗口重识别", 12),
         ("W20 合成 ≤20s 窗口重识别", 20), ("W30 合成 ≤30s 窗口重识别", 30), ("整段一次识别", 10_000)]
for cond, prep in [("干净", lambda a: a), ("底噪", noisy), ("几乎无停顿+底噪", lambda a: noisy(squeeze(a)))]:
    agg = {}
    for path in clips:
        a = prep(load(path)); ref = open(re.sub(r"-\d+\.wav$", ".txt", path)).read(); dur = len(a)/SR
        segs = smart(a)
        for name, cap in PLANS:
            CACHE.clear(); STAT.update(audio=0.0, infer=0.0)
            if cap is None:
                cs = current(a); hyp = "".join(asr(a, s, e) for s, e, _ in cs); forced = sum(x[2] for x in cs); nseg = len(cs)
            elif cap == 0:
                hyp = "".join(asr(a, s, e) for s, e, _ in segs); forced = sum(x[2] for x in segs); nseg = len(segs)
            else:
                ws = windows(segs, cap); hyp = "".join(asr(a, s, e) for s, e in ws); forced = 0; nseg = len(ws)
            ed, n = edits(ref, hyp)
            g = agg.setdefault(name, dict(ed=0, n=0, infer=0.0, dur=0.0, forced=0, segs=0, worst=0.0))
            g["ed"] += ed; g["n"] += n; g["infer"] += STAT["infer"]; g["dur"] += dur; g["forced"] += forced; g["segs"] += nseg
        print(f"{cond} {os.path.basename(path)}", file=sys.stderr)
    print(f"\n=== {cond}（{agg[PLANS[0][0]]['n']} 字）===")
    for name, _ in PLANS:
        g = agg[name]
        print(f"  {name:<20} 错字 {g['ed']:>4}  CER {g['ed']/g['n']*100:5.2f}%  段/窗 {g['segs']:>4}  被迫切 {g['forced']:>3}  单遍识别耗时/音频时长 {g['infer']/g['dur']*100:4.1f}%")
