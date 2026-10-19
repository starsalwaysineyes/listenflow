"""Compiled Swift chunker (new) × with/without gain, at the real and -6 dB levels."""
import sys, re, glob, numpy as np
exec(open("lab5.py").read().split("clips = sorted")[0])
clips = sorted(glob.glob("corpus/t*-*.wav"))
refs = {p: open(re.sub(r"-\d+\.wav$", ".txt", p)).read() for p in clips}
for lname, lev in {"实录(-44)": REAL_SPEECH_P90, "再低6dB(-50)": REAL_SPEECH_P90/2}.items():
    tot = {"新切分 原音量": 0, "新切分 + 提音量": 0, "新切分 + 提音量(无静音门槛)": 0}; n = 0; ns = 0
    for i, p in enumerate(clips):
        a = degrade(load(p), lev, i); segs = cut_swift(a); ns += len(segs)
        hyps = {"新切分 原音量": "".join(asr(a[s:e]) for s, e in segs),
                "新切分 + 提音量": "".join(asr(gain(a[s:e])) for s, e in segs),
                "新切分 + 提音量(无静音门槛)": "".join(asr(gain(a[s:e]), gate=False) for s, e in segs)}
        for k, h in hyps.items(): tot[k] += edits(refs[p], h)[0]
        n += len(re.sub(r"[^\w]|_", "", refs[p]))
        print(lname, p, tot, file=sys.stderr, flush=True)
    print(f"\n=== {lname}（Swift 片段 {ns}）===", flush=True)
    for k, v in tot.items(): print(f"  {k:<22} 错字 {v:>4}  CER {v/n*100:5.2f}%", flush=True)
