import subprocess, glob, re, sys, numpy as np
exec(open("lab3.py").read().split("clips = sorted")[0])   # model, asr, smart, windows, squeeze, edits
clips = sorted(glob.glob("corpus/t*-*.wav")); rng = np.random.default_rng(11)
def noisy(a):
    n = np.convolve(rng.normal(0, 1, len(a)), np.ones(8)/8, mode="same").astype(np.float32)
    return a + n*(0.006/np.sqrt(np.mean(n**2)))
def swift_segs(a):
    a.astype("<f4").tofile("/tmp/lf-cut.f32")
    out = subprocess.run(["../dbg/cut", "/tmp/lf-cut.f32"], capture_output=True, text=True).stdout.split("\n")
    return [tuple(int(x) for x in l.split()) for l in out if l.strip()]
for cond, prep in [("干净", lambda a: a), ("底噪", noisy), ("几乎无停顿+底噪", lambda a: noisy(squeeze(a)))]:
    tot = {"py": 0, "sw": 0, "n": 0, "pyseg": 0, "swseg": 0, "pyf": 0, "swf": 0}
    for p in clips:
        a = prep(load(p)); ref = open(re.sub(r"-\d+\.wav$", ".txt", p)).read()
        for key, segs in [("py", smart(a)), ("sw", swift_segs(a))]:
            CACHE.clear(); ed, n = edits(ref, "".join(asr(a, s, e) for s, e, _ in segs))
            tot[key] += ed; tot[key+"seg"] += len(segs); tot[key+"f"] += sum(1 for x in segs if x[2])
        tot["n"] += n
    print(f"{cond}: Python 错字 {tot['py']}（{tot['pyseg']} 段, 被迫 {tot['pyf']}）  Swift 错字 {tot['sw']}（{tot['swseg']} 段, 被迫 {tot['swf']}）  共 {tot['n']} 字")
