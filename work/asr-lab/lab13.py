"""Final A/B under one fixed condition: shipped (0.6.0) vs new Swift chunker, both as compiled."""
import sys, re, glob, subprocess, numpy as np
exec(open("lab5.py").read().split("clips = sorted")[0])
def cut(bin_, a):
    a.astype("<f4").tofile("/tmp/lf13.f32")
    return [tuple(int(v) for v in l.split()[:2]) for l in subprocess.run([bin_, "/tmp/lf13.f32"], capture_output=True, text=True).stdout.split("\n") if l.strip()]
SETS = {"讲课式停顿": ("corpus-pause/t*-pause.wav", r"-pause\.wav$"), "连续朗读": ("corpus/t*-*.wav", r"-\d+\.wav$")}
for sname, (glob_, pat) in SETS.items():
    clips = sorted(glob.glob(glob_))
    for lname, lev in {"正常电平": 0.08, "实录电平": REAL_SPEECH_P90, "再低6dB": REAL_SPEECH_P90/2}.items():
        tot = {"0.6.0": [0, 0], "新版": [0, 0]}; n = 0
        for i, p in enumerate(clips):
            ref = open(re.sub(pat, ".txt", p)).read(); n += len(re.sub(r"[^\w]|_", "", ref))
            a = degrade(load(p), lev, i)
            for k, b in [("0.6.0", "/tmp/cut-old"), ("新版", "../dbg/cut")]:
                segs = cut(b, a); tot[k][0] += edits(ref, "".join(asr(a[s:e]) for s, e in segs))[0]; tot[k][1] += len(segs)
        o, w = tot["0.6.0"][0], tot["新版"][0]
        print(f"{sname} · {lname}: 0.6.0 {o} 错 ({o/n*100:.1f}%)  →  新版 {w} 错 ({w/n*100:.1f}%)   片段 {tot['0.6.0'][1]}→{tot['新版'][1]}", flush=True)
