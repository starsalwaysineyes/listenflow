"""Chunker detection under low SNR: high-pass, smoothing, hysteresis. All followed by gain."""
import sys, re, glob, numpy as np
exec(open("lab5.py").read().split("clips = sorted")[0])        # model, asr, degrade, gain, cut_swift, noise
from scipy.signal import butter, sosfilt
SOS = butter(2, 200, btype="highpass", fs=SR, output="sos")

def chunk(a, hp=False, smooth=1, lo=None, ratio=2.5, min_s=3.0, max_s=8.0, gap_f=8, end_f=25, win=150, search_s=2.5):
    x = sosfilt(SOS, a) if hp else a                    # causal: only affects the decision signal
    n = len(x)//F; r = np.sqrt(np.mean(x[:n*F].reshape(n, F)**2, axis=1))
    if smooth > 1: r = np.convolve(r, np.ones(smooth)/smooth)[:n]   # causal moving average
    hist, out = [], []; active, start, quiet, pre, seg, was = False, 0, 0, 0, [], False
    for i in range(n):
        hist.append(r[i]); hist = hist[-win:]
        fl = float(np.sort(hist)[len(hist)//10])
        hi = min(max(0.003 if not hp else 0.0015, fl*ratio), 0.03)
        thr = (max(fl*lo, 0.0008) if (lo and was) else hi)
        speech = r[i] > thr; was = speech
        off = i*F
        if not active:
            if not speech: pre = min(pre+1, 10); continue
            active, start, quiet, seg = True, off - pre*F, 0, [0.0]*pre; pre = 0
        seg.append(r[i]); quiet = 0 if speech else quiet+1
        length = len(seg)*F/SR; end = off+F
        if quiet >= end_f and length >= 0.8: out.append((start, end)); active = False; continue
        if length >= min_s and quiet >= gap_f:
            cut = end - (quiet//2)*F; out.append((start, cut))
            carry = (end-cut)//F; start, seg = cut, seg[-carry:] if carry else []; continue
        if length >= max_s:
            lo_i = len(seg) - int(search_s*SR/F); t = np.convolve(seg[lo_i:], np.ones(5)/5, mode="same")
            k = lo_i + int(np.argmin(t[2:-2])) + 2; cut = start + k*F
            out.append((start, cut)); start, seg = cut, seg[k:]
    if active and len(seg)*F >= 1600: out.append((start, len(a)))
    return out

clips = sorted(glob.glob("corpus/t*-*.wav"))
refs = {p: open(re.sub(r"-\d+\.wav$", ".txt", p)).read() for p in clips}
VARIANTS = {
    "现状(Swift)":          None,
    "高通(门槛×2.0)":       dict(hp=True, ratio=2.0),
    "高通(门槛×1.7)":       dict(hp=True, ratio=1.7),
}
import os
def degrade_broad(clean, _lev, seed):
    rng = np.random.default_rng(seed); n = np.convolve(rng.normal(0, 1, len(clean)), np.ones(8)/8, mode="same")
    return (clean + n*(0.006/np.sqrt(np.mean(n**2)))).astype(np.float32)
LEVELS = {k: v for k, v in {"正常电平": 0.08, "实录(-44)": REAL_SPEECH_P90, "再低6dB(-50)": REAL_SPEECH_P90/2, "宽带噪声": -1}.items() if k in os.environ.get("LEVELS", "正常电平,实录(-44),再低6dB(-50)").split(",")}
for lname, lev in LEVELS.items():
    tot = {k: [0, 0, 0] for k in VARIANTS}
    for i, p in enumerate(clips):
        a = degrade_broad(load(p), lev, i) if lev < 0 else degrade(load(p), lev, i)
        for k, kw in VARIANTS.items():
            segs = cut_swift(a) if kw is None else chunk(a, **kw)
            ed, nref = edits(refs[p], "".join(asr(gain(a[s:e])) for s, e in segs))
            tot[k][0] += ed; tot[k][1] += nref; tot[k][2] += len(segs)
        print(lname, p, {k: v[0] for k, v in tot.items()}, file=sys.stderr, flush=True)
    print(f"\n=== {lname} ===", flush=True)
    for k, (ed, nref, ns) in tot.items():
        print(f"  {k:<16} 错字 {ed:>4}  CER {ed/nref*100:5.2f}%  片段 {ns}", flush=True)
