"""Low-level speech: simulate the 10-19 classroom recording (speech ≈ -44 dBFS,
real room noise ≈ -55 dBFS) on the scored corpus and compare front-end fixes."""
import wave, re, sys, glob, contextlib, subprocess, time, json
import numpy as np
from mlx_audio.stt.utils import load_model
from lab2_score import edits
SR, F = 16000, 320
def load(p):
    w = wave.open(p); return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768
def frms(x): 
    n = len(x)//F; return np.sqrt(np.mean(x[:n*F].reshape(n, F)**2, axis=1))

with contextlib.redirect_stdout(sys.stderr):
    M = load_model("mlx-community/Qwen3-ASR-1.7B-8bit")
    M.generate(np.zeros(64000, np.float32), max_tokens=8, verbose=False)
def asr(x, gate=True):
    if gate and np.sqrt(np.mean(x*x)) <= 0.0015: return ""       # worker's silence gate
    with contextlib.redirect_stdout(sys.stderr):
        return M.generate(x, language=None, max_tokens=512, temperature=0, verbose=False).text.strip()

# ---- real room noise from the user's recording: its quietest frames, stitched
real = np.fromfile("real-low.pcm", dtype="<i2").astype(np.float32)/32768
r = frms(real); q = r < np.percentile(r, 15)
noise = np.concatenate([real[i*F:(i+1)*F] for i in np.where(q)[0]])
REAL_SPEECH_P90 = float(np.percentile(r, 90))
print(f"真实录音: 说话 p90 {20*np.log10(REAL_SPEECH_P90):.1f} dBFS, 底噪 {20*np.log10(np.sqrt(np.mean(noise**2))):.1f} dBFS, 噪声样本 {len(noise)/SR:.1f}s", file=sys.stderr)

def degrade(clean, speech_p90, seed):
    rr = frms(clean); s = clean * (speech_p90 / np.percentile(rr[rr > 0.002], 90))
    k = np.random.default_rng(seed).integers(0, len(noise))
    nz = np.resize(np.roll(noise, -k), len(s))
    return (s + nz).astype(np.float32)

def cut_swift(a):
    a.astype("<f4").tofile("/tmp/lf5.f32")
    out = subprocess.run(["../dbg/cut", "/tmp/lf5.f32"], capture_output=True, text=True).stdout.split("\n")
    return [tuple(int(v) for v in l.split()[:2]) for l in out if l.strip()]

# ---- front-end treatments applied to one chunk before recognition
def gain(x, target=0.08, max_db=30):
    rr = frms(x)
    if len(rr) == 0: return x
    level = np.percentile(rr, 90)                         # loud frames ≈ speech
    g = min(target / max(level, 1e-6), 10**(max_db/20))
    y = x * g
    return np.tanh(y) if np.abs(y).max() > 0.9 else y      # soft limiter for rare clicks

def denoise(x, over=1.5, floor=0.15):
    n, h = 512, 128
    pad = np.concatenate([x, np.zeros(n)])
    win = np.hanning(n).astype(np.float32)
    frames = np.stack([pad[i:i+n]*win for i in range(0, len(x), h)])
    S = np.fft.rfft(frames, axis=1); P = np.abs(S)**2
    e = P.sum(1); nz = P[e <= np.percentile(e, 15)].mean(0)
    G = np.maximum(1 - over*nz/np.maximum(P, 1e-12), floor**2)**0.5
    Y = np.fft.irfft(S*G, n=n, axis=1)*win
    out = np.zeros(len(x)+n, np.float32); norm = np.zeros(len(x)+n, np.float32)
    for k, i in enumerate(range(0, len(x), h)):
        out[i:i+n] += Y[k]; norm[i:i+n] += win**2
    return (out/np.maximum(norm, 1e-6))[:len(x)].astype(np.float32)

clips = sorted(glob.glob("corpus/t*-*.wav"))
refs = {p: open(re.sub(r"-\d+\.wav$", ".txt", p)).read() for p in clips}
levels = {"实录电平(-44)": REAL_SPEECH_P90, "再低6dB(-50)": REAL_SPEECH_P90/2}
results = {}
for lname, lev in levels.items():
    for i, p in enumerate(clips):
        clean = load(p); a = degrade(clean, lev, i)
        segs = cut_swift(a)
        oracle = cut_swift(degrade(clean, 0.08, i) * 0 + clean)   # where speech really is
        rows = {
            "现状": "".join(asr(a[s:e]) for s, e in segs),
            "提音量": "".join(asr(gain(a[s:e])) for s, e in segs),
            "降噪+提音量": "".join(asr(gain(denoise(a[s:e]))) for s, e in segs),
            "理想切分+提音量": "".join(asr(gain(a[s:e])) for s, e in oracle),
        }
        for k, hyp in rows.items():
            ed, n = edits(refs[p], hyp)
            agg = results.setdefault(lname, {}).setdefault(k, [0, 0, 0])
            agg[0] += ed; agg[1] += n; agg[2] += max(0, n - len(re.sub(r"[^\w]|_", "", hyp)))
        cov = sum(e-s for s, e in segs)/len(a); covo = sum(e-s for s, e in oracle)/len(a)
        results[lname].setdefault("_cov", []).append((cov, covo, len(segs)))
        print(f"{lname} {p}: " + "  ".join(f"{k} {edits(refs[p], v)[0]}" for k, v in rows.items()) + f"  覆盖 {cov:.0%}/{covo:.0%}", file=sys.stderr)
for lname, rs in results.items():
    cov = rs.pop("_cov")
    print(f"\n=== {lname} 覆盖率 现状 {np.mean([c[0] for c in cov]):.0%} vs 理想 {np.mean([c[1] for c in cov]):.0%}，片段数 {sum(c[2] for c in cov)} ===")
    for k, (ed, n, short) in rs.items():
        print(f"  {k:<12} 错字 {ed:>4} / {n}  CER {ed/n*100:5.2f}%  少出的字 ≈{short}")
