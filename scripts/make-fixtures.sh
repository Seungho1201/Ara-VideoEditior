#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p TestArtifacts/fixtures
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=red:s=640x360:r=30:d=6' -f lavfi -i 'aevalsrc=0.6*sin(2*PI*440*t)*lt(mod(t\,1)\,0.15):s=48000:d=6' -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac -b:a 192k -shortest TestArtifacts/fixtures/base.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=blue:s=320x180:r=30:d=2' -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=2' -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac -shortest TestArtifacts/fixtures/overlay.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=0x00C080:s=640x360' -frames:v 1 TestArtifacts/fixtures/still.png
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=220:sample_rate=48000:duration=4' TestArtifacts/fixtures/tone.wav
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=white:s=64x64:r=30:d=1' -c:v libx264 -pix_fmt yuv420p -x264-params 'colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc' TestArtifacts/fixtures/hdr.mp4
printf 'not a movie\n' > TestArtifacts/fixtures/invalid.mov
