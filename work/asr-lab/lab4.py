import subprocess, numpy as np, re, sys
exec(open("lab2.py").read().split("# ---------------- strategies")[0])
from lab2_score import edits
def swift_segs(a):
    a.astype("<f4").tofile("/tmp/lf-cut.f32")
    out = subprocess.run(["../dbg/cut", "/tmp/lf-cut.f32"], capture_output=True, text=True).stdout.split("\n")
    return [tuple(int(x) for x in l.split()) for l in out if l.strip()]
def group(segs, cap, close_at=None, skip=0):
    """Greedy windows; optionally close as soon as a window reaches close_at s;
    `skip` leaves the first k segments alone to shift every boundary."""
    out, cur = [[s] for s in segs[:skip]], []
    for s in segs[skip:]:
        if cur and ((s[1]-cur[0][0])/SR > cap or (s[0]-cur[-1][1])/SR > 3): out.append(cur); cur = []
        cur.append(s)
        if close_at and (cur[-1][1]-cur[0][0])/SR >= close_at: out.append(cur); cur = []
    if cur: out.append(cur)
    return out
for name in ["noisy", "fast"]:
    a = np.fromfile(f"replay-{name}.pcm", dtype="<i2").astype(np.float32)/32768
    ref = open(f"replay-{name}.txt").read()
    segs = swift_segs(a)
    def score(groups):
        CACHE.clear()
        return edits(ref, "".join(asr(a, g[0][0], g[-1][1]) for g in groups))[0]
    print(f"\n=== {name}  单遍 {score([[s] for s in segs])} 错 ===")
    for label, kw in [("贪心≤12s", dict(cap=12)), ("贪心≤16s", dict(cap=16)), ("贪心≤20s", dict(cap=20)),
                      ("贪心≤30s", dict(cap=30)), ("满14s即关(≤20s)", dict(cap=20, close_at=14))]:
        runs = [score(group(segs, skip=k, **kw)) for k in range(3)]
        print(f"  {label:<16} 起点错开0/1/2段: {runs}  均值 {np.mean(runs):.1f}")
