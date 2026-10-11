#!/usr/bin/env python3
"""Resident, offline MLX ASR worker. stdin/stdout are a private JSON-lines pipe.

Audio is mono Float32 LE at 16 kHz. No audio files or network servers are created.
All library chatter goes to stderr; stdout is reserved for the protocol.
"""
import argparse
import base64
import contextlib
import json
import os
import sys
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def decode_audio(message):
    import numpy as np
    raw = base64.b64decode(message["audio"], validate=True)
    if len(raw) % 4 or len(raw) > 16000 * 4 * 12:
        raise ValueError("Invalid audio length (maximum 12 seconds)")
    samples = np.frombuffer(raw, dtype="<f4").copy()
    if not len(samples) or not np.isfinite(samples).all():
        raise ValueError("Invalid audio samples")
    return samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    started = time.monotonic()
    emit(type="status", message="正在加载本地模型…")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import numpy as np
            from mlx_audio.stt.utils import load_model
            model = load_model(args.model)
            # Warm Metal kernels before any live audio is captured.
            model.generate(np.zeros(64000, dtype=np.float32), max_tokens=8,
                           language="Chinese", verbose=False)
        emit(type="ready", model=args.model, load_seconds=time.monotonic() - started)
    except Exception as exc:
        emit(type="fatal", message=f"本地模型加载失败：{exc}")
        return 1

    for line in sys.stdin:
        message = {}
        try:
            message = json.loads(line)
            if message.get("type") == "shutdown":
                break
            if message.get("type") != "transcribe":
                raise ValueError("Unknown message type")
            samples = decode_audio(message)
            started = time.monotonic()
            rms = float(np.sqrt(np.mean(samples * samples)))
            text = ""
            if rms > 0.0015:
                with contextlib.redirect_stdout(sys.stderr):
                    result = model.generate(
                        samples, language=message.get("language") or None,
                        max_tokens=256, temperature=0, verbose=False,
                        hotwords=message.get("hotwords") or None,
                    )
                text = result.text.strip()
            emit(type="result", id=message["id"], text=text,
                 inference_seconds=time.monotonic() - started,
                 audio_seconds=len(samples) / 16000)
        except Exception as exc:
            emit(type="error", id=message.get("id"), message=str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
