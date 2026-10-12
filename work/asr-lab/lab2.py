"""Segmentation A/B on a 10-clip, 5-voice corpus with the real local model.
The smart chunker here is causal and mirrors the Swift implementation line by line."""
import wave, re, sys, json, contextlib, difflib, time, glob, os
import numpy as np
from mlx_audio.stt.utils import load_model
SR, F = 16000, 320

def load(p):
    w = wave.open(p); return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768
with contextlib.redirect_stdout(sys.stderr):
    M = load_model("mlx-community/Qwen3-ASR-1.7B-8bit")
    M.generate(np.zeros(64000, np.float32), max_tokens=8, verbose=False)
STAT = {"audio": 0.0, "infer": 0.0}
CACHE = {}
def asr(a, s, e):
    key = (id(a), s, e)
    if key in CACHE: return CACHE[key]
    x = a[s:e]; STAT["audio"] += len(x)/SR
    t = time.monotonic()
    if np.sqrt(np.mean(x*x)) <= 0.0015: out = ""
    else:
        with contextlib.redirect_stdout(sys.stderr):
            out = M.generate(x, language=None, max_tokens=512, temperature=0, verbose=False).text.strip()
    STAT["infer"] += time.monotonic()-t
    CACHE[key] = out
    return out

# ---------------- chunkers: return [(start, end, forced)] ----------------
def current(a):
    out, n, pre, active, quiet, start = [], 0, 0, False, 0, 0
    for off in range(0, len(a), F):
        part = a[off:off+F]; speech = np.sqrt(np.mean(part*part)) > 0.003
        if not active:
            if not speech: pre = min(pre+len(part), 3200); continue
            active, start, n = True, off-pre, pre; pre = 0
        n += len(part); quiet = 0 if speech else quiet+len(part)
        if n >= SR*4 or (quiet >= 8000 and n >= 12800):
            out.append((start, start+n, n >= SR*4)); active, n, quiet, pre = False, 0, 0, 0
    if active and n >= 1600: out.append((start, start+n, False))
    return out

def smart(a, min_s=3.0, max_s=8.0, gap_f=8, end_f=25, floor_win=150, search_s=2.5):
    """Causal: rolling 10th-percentile noise floor over the last 3 s."""
    hist, out = [], []
    active, start, quiet, pre = False, 0, 0, 0
    rms_seg = []                                  # per-frame RMS of the open segment
    for off in range(0, len(a)-F+1, F):
        r = float(np.sqrt(np.mean(a[off:off+F]**2)))
        hist.append(r); hist = hist[-floor_win:]
        thr = max(0.003, float(np.percentile(hist, 10))*2.5)
        speech = r > thr
        if not active:
            if not speech: pre = min(pre+1, 10); continue          # 200 ms pre-roll
            active, start, quiet = True, off - pre*F, 0
            rms_seg = [0.0]*pre; pre = 0
        rms_seg.append(r); quiet = 0 if speech else quiet+1
        length = len(rms_seg)*F/SR
        end = off + F
        if quiet >= end_f and length >= 0.8:                       # real pause: close and idle
            out.append((start, end, False)); active = False; continue
        if length >= min_s and quiet >= gap_f:                     # short gap: cut in its middle
            cut = end - (quiet//2)*F
            out.append((start, cut, False))
            carry = (end-cut)//F; start, rms_seg = cut, rms_seg[-carry:] if carry else []
            continue
        if length >= max_s:                                        # forced: quietest 100 ms in the tail
            lo = len(rms_seg) - int(search_s*SR/F)
            tail = np.convolve(rms_seg[lo:], np.ones(5)/5, mode="same")
            k = lo + int(np.argmin(tail[2:-2])) + 2
            cut = start + k*F
            out.append((start, cut, True))
            start, rms_seg = cut, rms_seg[k:]
    if active and len(rms_seg)*F >= 1600: out.append((start, len(a), False))
    return out

# ---------------- strategies: return (text, final_delay_list) ----------------
def independent(a, segs):
    return "".join(asr(a, s, e) for s, e, _ in segs), [0.0]*len(segs)

def pair_stitch(a, segs):
    if len(segs) < 2: return independent(a, segs)
    singles = [asr(a, s, e) for s, e, _ in segs]
    pairs = [asr(a, segs[i][0], segs[i+1][1]) for i in range(len(segs)-1)]
    text = pairs[0]
    for i in range(1, len(pairs)):
        shared = max(len(singles[i]), 4)
        head, tail = pairs[i][:int(shared*1.6)], text[-int(shared*1.6):]
        m = difflib.SequenceMatcher(None, tail, head, autojunk=False).find_longest_match(0, len(tail), 0, len(head))
        if m.size >= 2:
            mid = m.size//2; text = text[:len(text)-len(tail)+m.a+mid] + pairs[i][m.b+mid:]
        else:
            text += singles[i+1]
    # each segment is final only once the following one has ended
    delays = [(segs[i+1][1]-segs[i][1])/SR for i in range(len(segs)-1)] + [0.0]
    return text, delays

def forced_rejoin(a, segs, cap_s=12.0):
    """Decode each piece for display; wherever a cut was forced, re-decode the chain
    of pieces joined by forced cuts as one window and let that replace them."""
    for s, e, _ in segs: asr(a, s, e)                    # live display pass
    groups, cur = [], [segs[0]]
    for seg in segs[1:]:
        prev = cur[-1]
        if prev[2] and (seg[1]-cur[0][0])/SR <= cap_s: cur.append(seg)
        else: groups.append(cur); cur = [seg]
    groups.append(cur)
    text, delays = "", []
    for g in groups:
        if len(g) == 1: text += asr(a, g[0][0], g[0][1]); delays.append(0.0)
        else:
            text += asr(a, g[0][0], g[-1][1])
            delays += [(g[-1][1]-x[1])/SR for x in g]
    return text, delays

# ---------------- scoring ----------------
norm = lambda t: re.sub(r"[^\w]|_", "", t)
def edits(ref, hyp):
    r, h = norm(ref), norm(hyp); d = list(range(len(h)+1))
    for i in range(1, len(r)+1):
        prev, d[0] = d[0], i
        for j in range(1, len(h)+1):
            cur = min(d[j]+1, d[j-1]+1, prev+(r[i-1] != h[j-1])); prev, d[j] = d[j], cur
    return d[len(h)], len(r)

clips = sorted(glob.glob("corpus/t*-*.wav"))
rng = np.random.default_rng(7)
STRATS = [
    ("A 现状 4 秒硬切",          current, independent),
    ("B 停顿处切 3–8s",          smart,   independent),
    ("D 句级切 4–12s",           lambda a: smart(a, min_s=4, max_s=12), independent),
    ("C' B + 相邻两段合并拼接",   smart,   pair_stitch),
    ("F B + 仅在被迫切口合并重识别", smart,   forced_rejoin),
]
agg = {}
detail = []
for cond in ["干净", "底噪"]:
    for path in clips:
        a = load(path)
        if cond == "底噪":
            n = np.convolve(rng.normal(0, 1, len(a)), np.ones(8)/8, mode="same").astype(np.float32)
            a = a + n*(0.006/np.sqrt(np.mean(n**2)))
        ref = open(re.sub(r"-\d+\.wav$", ".txt", path)).read()
        dur = len(a)/SR
        CACHE.clear()
        for name, chunker, strat in STRATS:
            segs = chunker(a)
            STAT.update(audio=0.0, infer=0.0)
            for k in [k for k in CACHE]: pass
            before = dict(CACHE); CACHE.clear()          # charge every strategy its own compute
            hyp, delays = strat(a, segs)
            ed, n = edits(ref, hyp)
            g = agg.setdefault((cond, name), dict(ed=0, n=0, audio=0.0, infer=0.0, dur=0.0, segs=0, forced=0, delay=[]))
            g["ed"] += ed; g["n"] += n; g["audio"] += STAT["audio"]; g["infer"] += STAT["infer"]; g["dur"] += dur
            g["segs"] += len(segs); g["forced"] += sum(1 for x in segs if x[2]); g["delay"] += delays
            detail.append(dict(cond=cond, clip=os.path.basename(path), strat=name, ed=ed, n=n, hyp=hyp))
        print(f"done {cond} {os.path.basename(path)}", file=sys.stderr)
json.dump(detail, open("results2.json", "w"), ensure_ascii=False, indent=1)
for cond in ["干净", "底噪"]:
    print(f"\n=== {cond}（共 {agg[(cond, STRATS[0][0])]['n']} 字）===")
    print(f"  {'策略':<22}{'错字':>5}{'CER':>8}{'段数':>6}{'被迫切':>7}{'识别量':>7}{'GPU占用':>8}{'定稿额外等待(平均/最大)':>16}")
    for name, *_ in STRATS:
        g = agg[(cond, name)]
        d = g["delay"]; nz = [x for x in d if x > 0]
        print(f"  {name:<22}{g['ed']:>5}{g['ed']/g['n']*100:>7.2f}%{g['segs']:>6}{g['forced']:>7}"
              f"{g['audio']/g['dur']:>6.2f}×{g['infer']/g['dur']*100:>7.1f}%"
              f"   {np.mean(d):.1f}s / {max(d) if d else 0:.1f}s（受影响 {len(nz)} 段）")
