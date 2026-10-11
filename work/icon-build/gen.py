import json, base64, urllib.request, pathlib, sys
cred = json.load(open("/Users/aurora/.config/memtensor/image-gen-20261008.json"))
key = cred["keys"][0]["api_key"]
base = cred["base_url"].rstrip("/")
prompt = (
 "A macOS application icon. Rounded-square (squircle) app icon on a deep indigo-to-teal "
 "gradient background with subtle top-down lighting. The central mark is three concentric "
 "sound-wave ripple arcs radiating from a single small filled dot at the left-center, and "
 "a smooth flowing horizontal stream line passing through them to the right, suggesting "
 "continuous transcription flow. The ripple arcs and stream line are bright mint-cyan with "
 "a soft glow. Minimal, geometric, flat-but-dimensional modern Apple design language. "
 "Centered composition, generous padding from the icon edge, no text, no letters, no words. "
 "High contrast, clean silhouette that stays readable when very small. 1024x1024."
)
body = json.dumps({"model": "gpt-image-2.5-flare", "prompt": prompt, "size": "1024x1024", "n": 1}).encode()
req = urllib.request.Request(base + "/images/generations", data=body,
    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    resp = json.load(urllib.request.urlopen(req, timeout=300))
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read().decode()[:800]); sys.exit(1)
item = resp["data"][0]
out = pathlib.Path("icon-raw.png")
if item.get("b64_json"):
    out.write_bytes(base64.b64decode(item["b64_json"]))
else:
    urllib.request.urlretrieve(item["url"], out)
print("saved", out, out.stat().st_size, "bytes")
