#!/usr/bin/env python3
"""Create local-only synthetic STT diagnostics, not a production qualification corpus."""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import random
import subprocess
import sys
import wave

TEXT = ('Please save the recording before closing the window. The project review is scheduled for Thursday morning. '
        'Jordan will check the microphone settings, and Morgan will prepare the final report. '
        'The last action is to confirm that every recording can be recovered after a restart.')
TAIL = ('The final decision is to keep the original audio until the library has accepted it. '
        'No participant approved a price change. Please send the revised notes tomorrow afternoon.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    entries = []
    def read(path):
        with wave.open(str(path), 'rb') as f:
            assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, 16000)
            samples = array.array('h', f.readframes(f.getnframes()))
            if sys.byteorder != 'little': samples.byteswap()
            return samples
    def write(path, samples):
        values = array.array('h', (max(-32768, min(32767, round(v))) for v in samples))
        if sys.byteorder != 'little': values.byteswap()
        with wave.open(str(path), 'wb') as f:
            f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            f.writeframes(values.tobytes())
    def synth(name, voice, text):
        aiff = root / (name + '.aiff')
        wav = root / (name + '.wav')
        subprocess.run(['say', '-v', voice, '-r', '165', '-o', str(aiff), text], check=True, timeout=60)
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(aiff), '-ac', '1', '-ar', '16000',
                        '-c:a', 'pcm_s16le', str(wav)], check=True, timeout=60)
        aiff.unlink()
        return wav
    def add(name, path, text, maximum, vad, condition):
        samples = read(path)
        entries.append({'id': name, 'audio': str(path), 'reference': text, 'maximumWER': maximum,
                        'vad': vad, 'durationSeconds': len(samples) / 16000,
                        'condition': condition, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    clean = synth('clean-samantha', 'Samantha', TEXT)
    add('clean-samantha', clean, TEXT, 0.12, False, 'installed en_US synthetic voice')
    british = synth('clean-daniel', 'Daniel', TEXT)
    add('clean-daniel', british, TEXT, 0.12, False, 'installed en_GB synthetic voice')
    quiet = synth('quiet-karen', 'Karen', TEXT)
    write(quiet, (v * 0.05 for v in read(quiet)))
    add('quiet-karen', quiet, TEXT, 0.20, False, 'installed en_AU voice, amplitude reduced by 26 dB')
    noisy = root / 'noise-samantha.wav'
    samples = read(clean)
    rms = math.sqrt(sum(float(v) * v for v in samples) / len(samples))
    rng = random.Random(20260905)
    write(noisy, (v + rng.gauss(0, rms / math.sqrt(10)) for v in samples))
    add('noise-samantha', noisy, TEXT, 0.20, False, 'deterministic Gaussian noise, nominal 10 dB SNR')
    tail = synth('tail', 'Daniel', TAIL)
    long = root / 'speech-with-silence.wav'
    write(long, list(read(british)) + [0] * (5 * 16000) + list(read(tail)) + [0] * (3 * 16000) + list(read(clean)))
    add('speech-with-silence', long, TEXT + ' ' + TAIL + ' ' + TEXT, 0.0, True,
        'synthetic speech separated by five and three seconds of silence; VAD requested')
    add('speech-with-silence-no-vad', long, TEXT + ' ' + TAIL + ' ' + TEXT, 0.0, False,
        'same exact long fixture with VAD disabled for paired comparison')
    for original, name in [(quiet, 'quiet-long'), (noisy, 'noise-long')]:
        output = root / (name + '.wav')
        values = read(original)
        write(output, list(values) + [0] * (4 * 16000) + list(values))
        add(name, output, TEXT + ' ' + TEXT, 0.20, True,
            'additional VAD holdout with four seconds of silence')
    (root / 'corpus.json').write_text(json.dumps({'classification': 'synthetic diagnostic, not production corpus qualification',
        'generator': 'local macOS say and ffmpeg; no user recordings', 'cases': entries}, indent=2) + '\n')
    print(root / 'corpus.json')

if __name__ == '__main__': main()
