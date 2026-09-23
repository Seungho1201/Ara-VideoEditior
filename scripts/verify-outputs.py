#!/usr/bin/env python3
"""Independent validation of FrameProbe artifacts. FFmpeg is a test tool, never an app dependency."""
import array
from fractions import Fraction
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
fixtures = root / 'TestArtifacts/fixtures'
results = root / 'TestArtifacts/results'
ffmpeg = shutil.which('ffmpeg')
ffprobe = shutil.which('ffprobe')
assert ffmpeg and ffprobe, 'Install FFmpeg to run independent output checks.'

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

report = {'streams': {}, 'audio': {}, 'visuals': {}}
for name, size, rate, frames in [
    ('validation-1080.mp4', (1920, 1080), Fraction(30), 195),
    ('validation-4k.mp4', (3840, 2160), Fraction(30), 30),
    ('validation-audio-only.mp4', (1920, 1080), Fraction(30), 30),
    ('validation-2997.mp4', (1920, 1080), Fraction(30000, 1001), 31),
]:
    metadata = json.loads(run(ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(results / name)))
    video = next(s for s in metadata['streams'] if s['codec_type'] == 'video')
    audio = next(s for s in metadata['streams'] if s['codec_type'] == 'audio')
    duration = float(Fraction(frames) / rate)
    assert video['codec_name'] == 'h264' and audio['codec_name'] == 'aac'
    assert (video['width'], video['height']) == size
    assert Fraction(video['r_frame_rate']) == rate, video
    assert Fraction(video['avg_frame_rate']) == rate, video
    assert int(video['nb_frames']) == frames
    assert abs(float(video['duration']) - duration) < 2e-6, video
    assert abs(float(audio['duration']) - duration) < 2 / 48000, audio
    assert float(video['start_time']) == float(audio['start_time']) == 0
    assert all(video[key] == 'bt709' for key in ['color_space', 'color_transfer', 'color_primaries'])
    assert audio['sample_rate'] == '48000' and audio['channels'] == 2
    report['streams'][name] = {'size': size, 'fps': str(rate), 'frames': frames, 'duration': video['duration'], 'audio_duration': audio['duration'], 'codecs': 'H.264 / AAC', 'color': 'Rec.709'}
    print('PASS streams:', name, size, str(rate), frames)


def pcm(path, first_channel=False):
    args = [ffmpeg, '-v', 'error', '-i', str(path), '-map', '0:a:0']
    if first_channel:
        args += ['-af', 'pan=mono|c0=c0']  # Avoid stereo-to-mono summation gain.
    args += ['-ac', '1', '-ar', '48000', '-f', 'f32le', '-']
    data = array.array('f', run(*args))
    if sys.byteorder != 'little': data.byteswap()
    return data


def rms(data, start, end):
    section = data[round(start * 48000):round(end * 48000)]
    return math.sqrt(sum(v*v for v in section) / len(section))

source = pcm(fixtures / 'base.mp4')
output = pcm(results / 'validation-1080.mp4', True)
ratio = rms(output, .03, .12) / rms(source, .03, .12)
assert abs(ratio - .25) < .02, ratio
silence = rms(output, 3.1, 3.4)
assert silence < .0001, silence
onsets = []
for expected in [0, 1, 2, 4.5, 5.5]:
    start = max(0, round((expected - .04) * 48000))
    stop = round((expected + .04) * 48000)
    detected = next(i / 48000 for i in range(start, stop) if abs(output[i]) > .04)
    assert abs(detected - expected) < .005, (expected, detected)
    onsets.append({'expected_seconds': expected, 'actual_seconds': detected})
# The muted 880 Hz overlay must not leak into the gap between base beeps.
assert rms(output, 1.3, 1.8) < .001
report['audio'] = {'volume_ratio_left_channel': ratio, 'requested_volume': .25, 'gap_rms': silence, 'beep_onsets': onsets, 'muted_overlay': 'pass'}
print('PASS audio: 25% volume, mute, silent gap, source-to-timeline synchronization')


def pixels(seconds):
    data = run(ffmpeg, '-v', 'error', '-ss', str(seconds), '-i', str(results / 'validation-1080.mp4'), '-frames:v', '1', '-vf', 'scale=320:180', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-')
    assert len(data) == 320 * 180 * 3
    return list(zip(data[::3], data[1::3], data[2::3]))

red = pixels(.5)
assert sum(r > 200 and g < 30 and b < 30 for r,g,b in red) > len(red) * .98
layer = pixels(1.5)
blue_area = [i for i, (r,g,b) in enumerate(layer) if b > 80 and b > g * 1.5]
assert .15 < len(blue_area) / len(layer) < .35
assert sum(i % 320 for i in blue_area) / len(blue_area) > 200  # x = +20% canvas
text = pixels(3.5)
glyphs = [i for i,(r,g,b) in enumerate(text) if g > 150 and b > 80 and g > r * 1.1]
assert len(glyphs) > 300
assert sum(i // 320 for i in glyphs) / len(glyphs) > 120  # y = +25% canvas
assert sum(max(p) < 20 for p in text) > len(text) * .95
still = pixels(6.25)
assert sum(g > 80 and g > r*2 and g > b*1.2 for r,g,b in still) > len(still) * .98
report['visuals'] = {'base_red': 'pass', 'overlaid_transformed_video': 'pass', 'text_in_gap': 'pass', 'still_above_base': 'pass', 'overlay_fraction': len(blue_area)/len(layer), 'text_pixels': len(glyphs)}
print('PASS pixels: base, V2 composition/transform, mint text, still')
assert not list(results.glob('*.partial*')) and not list(results.glob('.frame-*.work'))
(results / 'independent-validation.json').write_text(json.dumps(report, indent=2) + '\n')
(results / 'audio-analysis.json').write_text(json.dumps(report['audio'], indent=2) + '\n')
print('ALL INDEPENDENT CHECKS PASSED')
