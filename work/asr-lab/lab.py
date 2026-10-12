"""Offline A/B of segmentation strategies on the real local model. Ground truth known."""
import wave, re, sys, json, contextlib, difflib, time
import numpy as np
from mlx_audio.stt.utils import load_model

SR = 16000
def load(p):
    w = wave.open(p); return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768

with contextlib.redirect_stdout(sys.stderr):
    M = load_model("mlx-community/Qwen3-ASR-1.7B-8bit")
    M.generate(np.zeros(64000, np.float32), max_tokens=8, verbose=False)
CALLS = {"n": 0, "sec": 0.0}
def asr(x, context=None):
    CALLS["n"] += 1; CALLS["sec"] += len(x)/SR
    if np.sqrt(np.mean(x*x)) <= 0.0015: return ""
    with contextlib.redirect_stdout(sys.stderr):
        r = M.generate(x, language=None, max_tokens=512, temperature=0, verbose=False,
                       system_prompt=context)
    return r.text.strip()

# ---------- segmentation ----------
def current_chunker(a):
    """Exact port of AudioChunker.swift (0.5.0)."""
    out, samples, pre, active, quiet, start = [], [], [], False, 0, 0
    for off in range(0, len(a), 320):
        part = a[off:off+320]; speech = np.sqrt(np.mean(part*part)) > 0.003
        if not active:
            if not speech:
                pre = (pre + list(part))[-3200:]; continue
            active, samples, start = True, list(pre), off - len(pre); pre = []
        samples += list(part); quiet = 0 if speech else quiet + len(part)
        if len(samples) >= SR*4 or (quiet >= 8000 and len(samples) >= 12800):
            out.append((start, start+len(samples))); samples, pre, active, quiet = [], [], False, 0
    if active and len(samples) >= 1600: out.append((start, start+len(samples)))
    return out

def smart_chunker(a, min_s=3.0, max_s=8.0, gap_ms=160):
    """Cut in the quietest gap once a segment is long enough; adaptive noise floor."""
    f = 320; rms = np.array([np.sqrt(np.mean(a[i:i+f]**2)) for i in range(0, len(a)-f+1, f)])
    floor = np.percentile(rms, 10); thr = max(0.003, floor*3)
    quiet = rms < thr
    out, s = [], 0
    gap_frames = int(gap_ms/20)
    i = 0
    while i < len(rms):
        seg_len = (i - s)*f/SR
        if seg_len >= min_s and i >= gap_frames and quiet[i-gap_frames:i].all():
            cut = i - gap_frames//2; out.append((s*f, cut*f)); s = cut
        elif seg_len >= max_s:
            lo = s + int((max_s-2.5)*SR/f)            # quietest 100 ms in the last 2.5 s
            win = np.convolve(rms[lo:i], np.ones(5)/5, mode="same")
            cut = lo + int(np.argmin(win)); out.append((s*f, cut*f)); s = cut
        i += 1
    if (len(rms)-s)*f > 1600: out.append((s*f, len(a)))
    return out

# ---------- strategies ----------
def independent(a, segs, ctx=False):
    texts, prev = [], ""
    for s, e in segs:
        t = asr(a[s:e], context=(f"上文：{prev[-120:]}" if ctx and prev else None))
        texts.append(t); prev += t
    return "".join(texts)

def pair_merge(a, segs):
    """User's idea: decode c_i+c_{i+1} windows and stitch overlaps by text alignment."""
    if len(segs) < 2: return independent(a, segs)
    singles = [asr(a[s:e]) for s, e in segs]
    pairs = [asr(a[segs[i][0]:segs[i+1][1]]) for i in range(len(segs)-1)]
    text = pairs[0]
    for i in range(1, len(pairs)):
        shared = max(len(singles[i]), 4)
        head, tail = pairs[i][:int(shared*1.6)], text[-int(shared*1.6):]
        m = difflib.SequenceMatcher(None, tail, head, autojunk=False).find_longest_match(0, len(tail), 0, len(head))
        if m.size >= 2:
            mid = m.size // 2
            text = text[:len(text)-len(tail)+m.a+mid] + pairs[i][m.b+mid:]
        else:
            text += pairs[i][len(singles[i]):] if pairs[i].startswith(singles[i][:2]) else singles[i+1]
    return text

# ---------- scoring ----------
def norm(t):
    t = re.sub(r"[\s，。！？、；：,.!?;:“”\"'（）()《》—…·-]", "", t)
    return t
def cer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h)+1))
    for i in range(1, len(r)+1):
        prev, d[0] = d[0], i
        for j in range(1, len(h)+1):
            cur = min(d[j]+1, d[j-1]+1, prev + (r[i-1] != h[j-1])); prev, d[j] = d[j], cur
    return d[len(h)]/len(r)

ref = open("text.txt").read().strip()
clean = load("speech.wav")
rng = np.random.default_rng(7)
noise = rng.normal(0, 1, len(clean)).astype(np.float32)
noise = np.convolve(noise, np.ones(8)/8, mode="same")            # softer, room-like hiss
noisy = clean + noise * (0.006/np.sqrt(np.mean(noise**2)))      # floor RMS ≈ 0.006, above the 0.003 gate

results = {}
for name, a in [("干净", clean), ("有底噪", noisy)]:
    cur, smart, sent = current_chunker(a), smart_chunker(a), smart_chunker(a, min_s=4, max_s=15, gap_ms=240)
    hard = sum(1 for s, e in cur if (e-s) >= SR*3.95)
    rows = []
    def run(label, fn, segs):
        CALLS.update(n=0, sec=0.0); t = time.monotonic(); hyp = fn(); dt = time.monotonic()-t
        lens = [(e-s)/SR for s, e in segs]
        rows.append(dict(策略=label, CER=round(cer(ref, hyp)*100, 2), 段数=len(segs),
                         平均段长=round(float(np.mean(lens)), 1), 识别音频倍数=round(CALLS["sec"]/(len(a)/SR), 2),
                         耗时=round(dt, 1), 文本=hyp))
    run("A 现状：4 秒硬切", lambda: independent(a, cur), cur)
    run("B 静音处切（3–8 秒）", lambda: independent(a, smart), smart)
    run("C 你的方案：A 切法 + 相邻两段合并识别", lambda: pair_merge(a, cur), cur)
    run("C' 你的方案：B 切法 + 相邻两段合并识别", lambda: pair_merge(a, smart), smart)
    run("D 句级切分（4–15 秒）", lambda: independent(a, sent), sent)
    run("E D + 上文作为上下文", lambda: independent(a, sent, ctx=True), sent)
    results[name] = dict(hard=f"{hard}/{len(cur)}", rows=rows)
json.dump(results, open("results.json", "w"), ensure_ascii=False, indent=1)
for name, r in results.items():
    print(f"\n=== {name}（现状切法硬切 {r['hard']}）===")
    for x in r["rows"]:
        print(f"  {x['策略']:<26} CER {x['CER']:>5}%  段数 {x['段数']:>3}  平均段长 {x['平均段长']:>4}s  识别量 {x['识别音频倍数']}×  耗时 {x['耗时']}s")
