"""Low-level speech for Doubao: build the conditions as 16 kHz 16-bit PCM files.

Two ways a recording ends up quiet:
  F  far-field: the speaker is far away, the room noise stays where it is
     (speech scaled down, real room noise at its recorded level);
  Q  quiet input: the input volume is low, so speech and noise drop together.
Treatments are applied to the float signal before it is made 16-bit, as the app would.
Run from work/asr-lab; writes to ../dbg/lab14 (not in the repository).
"""
import wave, sys, json
import numpy as np
SR, F = 16000, 320
OUT = "../dbg/lab14/"
def load(p):
    w = wave.open(p); return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768
def frms(x):
    n = len(x)//F; return np.sqrt(np.mean(x[:n*F].reshape(n, F)**2, axis=1))
db = lambda v: 20*np.log10(max(float(v), 1e-9))

# Real room noise from the 10-19 classroom recording: its quietest frames, stitched (as lab5).
real = np.fromfile("real-low-frozen.pcm", dtype="<i2").astype(np.float32)/32768
r = frms(real); q = r < np.percentile(r, 15)
noise = np.concatenate([real[i*F:(i+1)*F] for i in np.where(q)[0]])
REAL_P90 = float(np.percentile(r, 90))
del real

CLIPS = ["t2", "t4"]
clean = np.concatenate([np.concatenate([load(f"corpus/{c}-200.wav"), np.zeros(SR, np.float32)]) for c in CLIPS])
ref = "".join(open(f"corpus/{c}.txt").read() for c in CLIPS)
rr = frms(clean); P90 = float(np.percentile(rr[rr > 0.002], 90))
speech = rr > P90 * 0.05                       # frames where someone is really talking
nz = np.resize(np.roll(noise, -12345), len(clean))

def far(level):  return (clean * (level / P90) + nz).astype(np.float32)
def gain(x, target=0.08):
    level = np.percentile(frms(x), 90)
    y = x * (target / max(level, 1e-6))
    return np.tanh(y) if np.abs(y).max() > 0.9 else y
def denoise(x, over=1.5, floor=0.15):          # spectral subtraction, as lab5
    n, h = 512, 128
    pad = np.concatenate([x, np.zeros(n)]); win = np.hanning(n).astype(np.float32)
    frames = np.stack([pad[i:i+n]*win for i in range(0, len(x), h)])
    S = np.fft.rfft(frames, axis=1); P = np.abs(S)**2
    e = P.sum(1); nzp = P[e <= np.percentile(e, 15)].mean(0)
    G = np.maximum(1 - over*nzp/np.maximum(P, 1e-12), floor**2)**0.5
    Y = np.fft.irfft(S*G, n=n, axis=1)*win
    out = np.zeros(len(x)+n, np.float32); norm = np.zeros(len(x)+n, np.float32)
    for k, i in enumerate(range(0, len(x), h)):
        out[i:i+n] += Y[k]; norm[i:i+n] += win**2
    return (out/np.maximum(norm, 1e-6))[:len(x)].astype(np.float32)

normal = far(0.08)
conditions = {
    # sent to Doubao
    "N":            normal,
    "F44-raw":      far(REAL_P90),
    "F44-gain":     gain(far(REAL_P90)),
    "F44-denoise":  gain(denoise(far(REAL_P90))),
    "F50-raw":      far(REAL_P90/2),
    "F50-gain":     gain(far(REAL_P90/2)),
    "F50-denoise":  gain(denoise(far(REAL_P90/2))),
    "Q30-raw":      normal * 10**(-30/20),
    "Q40-raw":      normal * 10**(-40/20),
    # speech detection only (never sent)
    "F56-raw":      far(REAL_P90/4),
    "F62-raw":      far(REAL_P90/8),
    "Q20-raw":      normal * 10**(-20/20),
    "Q50-raw":      normal * 10**(-50/20),
}
meta = {"seconds": len(clean)/SR, "chars": len(ref), "speech_frames": speech.astype(int).tolist(), "levels": {}}
for name, x in conditions.items():
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2"); pcm.tofile(OUT + name + ".pcm")
    back = pcm.astype(np.float32)/32768; fr = frms(back)
    meta["levels"][name] = {"speech_p90_db": round(db(np.percentile(fr[speech[:len(fr)]], 90)), 1),
                            "floor_db": round(db(np.sqrt(np.mean(back[:len(fr)*F].reshape(-1, F)[~speech[:len(fr)]]**2))), 1)}
open(OUT + "ref.txt", "w").write(ref)
json.dump(meta, open(OUT + "meta.json", "w"))
print(f"真实录音：说话 p90 {db(REAL_P90):.1f} dBFS，底噪样本 {db(np.sqrt(np.mean(noise**2))):.1f} dBFS（{len(noise)/SR:.0f} 秒）")
print(f"语料：{'+'.join(CLIPS)}，{len(clean)/SR:.1f} 秒，其中说话 {speech.mean()*len(clean)/SR:.1f} 秒")
for name, lv in meta["levels"].items(): print(f"  {name:<12} 说话 p90 {lv['speech_p90_db']:>6} dBFS   间隙 {lv['floor_db']:>6} dBFS")
