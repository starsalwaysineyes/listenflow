"""Speech detection on quiet audio: how much real speech the app would not stream.
Uses the app's own SpeechGate (lab14 gate). Nothing is sent anywhere."""
import json, subprocess
D = "../dbg/lab14/"; F = 320
meta = json.load(open(D + "meta.json")); speech = meta["speech_frames"]; total = sum(speech) * F / 16000
ROWS = [("远场：正常电平", "N"), ("远场：实录电平", "F44-raw"), ("远场：再低 6 dB", "F50-raw"), ("远场：再低 12 dB", "F56-raw"),
        ("远场：再低 18 dB", "F62-raw"), ("输入音量低：−20 dB", "Q20-raw"), ("输入音量低：−30 dB", "Q30-raw"),
        ("输入音量低：−40 dB", "Q40-raw"), ("输入音量低：−50 dB", "Q50-raw"),
        ("实录电平，先提音量", "F44-gain"), ("再低 6 dB，先提音量", "F50-gain")]
print(f"语料 {meta['seconds']:.1f} 秒，其中说话 {total:.1f} 秒")
print(f"{'条件':<16}{'说话 p90':>10}{'间隙':>9}{'连接数':>6}{'送出秒数':>9}{'没送出的说话':>12}")
for label, name in ROWS:
    out = subprocess.run([D + "lab14", "gate", D + name + ".pcm"], capture_output=True, text=True).stdout.split("\n")
    ranges = [tuple(int(v) for v in l.split()) for l in out if l.strip()]
    sent = [False] * len(speech)
    for a, b in ranges:
        for i in range(a // F, min(len(speech), -(-b // F))): sent[i] = True
    missed = sum(1 for s, t in zip(speech, sent) if s and not t) * F / 16000
    lv = meta["levels"][name]
    print(f"{label:<16}{lv['speech_p90_db']:>8} dB{lv['floor_db']:>7} dB{len(ranges):>6}{sum(b - a for a, b in ranges) / 16000:>9.1f}{missed:>8.1f} 秒 {missed / total:>5.0%}")
