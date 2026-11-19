"""Scores what Doubao returned for each condition (../dbg/lab14/out/*.json)."""
import json, re
from lab2_score import edits
D = "../dbg/lab14/"
ref = open(D + "ref.txt").read()
def plain(t):                                  # the service writes 「百分之四」 as 4%: leave numbers out of it
    t = re.sub(r"百分之", "", t)
    t = re.sub(r"(?<=[零一二两三四五六七八九十百千万亿])点(?=[零一二三四五六七八九])", "", t)
    return re.sub(r"[0-9零一二两三四五六七八九十百千万亿%％.]", "", t)
ROWS = [("正常电平（−22）", "N"), ("实录电平（−40），原样", "F44-raw"), ("　先提音量", "F44-gain"), ("　先降噪再提音量", "F44-denoise"),
        ("再低 6 dB（−45），原样", "F50-raw"), ("　先提音量", "F50-gain"), ("　先降噪再提音量", "F50-denoise"),
        ("整体 −30 dB（−52），原样", "Q30-raw"), ("整体 −40 dB（−62），原样", "Q40-raw"),
        ("　存成 16 位后再放大 40 dB", "Q40-gain")]
n1, n2 = edits(ref, "")[1], edits(plain(ref), "")[1]
print(f"参考文本 {n1} 字；不计数字写法 {n2} 字")
print(f"{'条件':<20}{'句数':>4}{'出字':>6}{'错字(原始)':>10}{'错字(不计数字)':>12}")
for label, name in ROWS:
    rows = json.load(open(D + "out/" + name + ".json"))
    hyp = "".join(r["text"] for r in rows)
    e1, e2 = edits(ref, hyp)[0], edits(plain(ref), plain(hyp))[0]
    print(f"{label:<20}{len(rows):>4}{edits(hyp, '')[1]:>6}{e1:>8}{e2:>8}  {e2 / n2:5.1%}")
