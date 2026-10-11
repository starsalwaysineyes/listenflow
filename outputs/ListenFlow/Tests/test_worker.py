"""Uses the actual cached model. Pass a local 16 kHz mono WAV test fixture."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import time
import wave
import numpy as np

root = Path(__file__).resolve().parents[1]
worker = subprocess.Popen([sys.executable, '-u', str(root/'Backend/asr_worker.py'),
    '--model', 'mlx-community/Qwen3-ASR-1.7B-8bit'], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

def send(**message):
    worker.stdin.write(json.dumps(message) + '\n')
    worker.stdin.flush()

def receive():
    line = worker.stdout.readline()
    assert line, 'Worker exited unexpectedly'
    return json.loads(line)

try:
    while True:
        message = receive()
        assert message['type'] != 'fatal', message
        if message['type'] == 'ready': break
    print('Model loaded and warmed:', round(message['load_seconds'], 2), 'seconds')
    send(type='transcribe', id='bad', audio='!invalid!')
    assert receive()['type'] == 'error'
    silence = np.zeros(64000, dtype='<f4')
    send(type='transcribe', id='silence', audio=base64.b64encode(silence.tobytes()).decode())
    result = receive()
    assert result['id'] == 'silence' and result['text'] == ''
    with wave.open(sys.argv[1], 'rb') as f:
        assert f.getframerate() == 16000 and f.getnchannels() == 1 and f.getsampwidth() == 2
        audio = np.frombuffer(f.readframes(f.getnframes()), dtype='<i2').astype('<f4') / 32768
    latencies = []
    for i, offset in enumerate(range(0, len(audio), 64000)):
        samples = audio[offset:offset+64000]
        began = time.monotonic()
        send(type='transcribe', id=str(i), audio=base64.b64encode(samples.tobytes()).decode(), language='Chinese')
        result = receive()
        assert result['type'] == 'result' and result['id'] == str(i), result
        duration = len(samples)/16000
        latency = duration + time.monotonic() - began
        latencies.append(latency)
        print(f'Chunk {i}: {duration:.2f}s audio, {result["inference_seconds"]:.3f}s inference, estimated first-sample latency {latency:.2f}s; {result["text"]}')
    assert max(latencies) < 10, 'Fixture exceeds latency target'
    print('PASS: resident real-model ASR, malformed-input recovery, silence gate, ordered chunks, <10s fixture latency')
finally:
    if worker.poll() is None:
        send(type='shutdown')
        worker.wait(timeout=10)
