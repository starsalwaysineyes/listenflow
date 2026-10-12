import time, wave, numpy as np, contextlib, sys
from mlx_audio.stt.utils import load_model
w = wave.open("speech.wav"); a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768
with contextlib.redirect_stdout(sys.stderr):
    m = load_model("mlx-community/Qwen3-ASR-1.7B-8bit")
    m.generate(np.zeros(64000, np.float32), max_tokens=8, language="Chinese", verbose=False)
for sec in [2, 4, 6, 8, 12, 16]:
    seg = a[160000:160000+sec*16000]
    ts = []
    for _ in range(3):
        t = time.monotonic()
        with contextlib.redirect_stdout(sys.stderr):
            m.generate(seg, language="Chinese", max_tokens=256, temperature=0, verbose=False)
        ts.append(time.monotonic()-t)
    t = sorted(ts)[1]
    print(f"{sec:>2}s 音频 → 识别 {t:.2f}s  实时率 {t/sec:.2f}")
