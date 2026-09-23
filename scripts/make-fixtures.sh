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
# Portrait phone video: landscape frames plus a 90° display matrix. Guards the renderer's orientation.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=2' -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 TestArtifacts/fixtures/pattern.mp4
ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i TestArtifacts/fixtures/pattern.mp4 -c copy TestArtifacts/fixtures/rotated.mp4
# A 4K HLG phone-style clip (10-bit HEVC at 29.97 fps, portrait display matrix): larger than FHD, so
# the preview reads a 1080p proxy of it. Guards exact proxy timestamps (29.97 is off the 1/600 grid),
# colour tags, orientation and preview parity.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=3840x2160:rate=30000/1001:duration=1.5' -c:v hevc_videotoolbox -tag:v hvc1 -profile:v main10 -pix_fmt p010le -b:v 20M -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9 TestArtifacts/fixtures/hlg4k-landscape.mov
ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i TestArtifacts/fixtures/hlg4k-landscape.mov -c copy TestArtifacts/fixtures/hlg4k.mov
# Open-GOP HEVC cut mid-GOP: as with some phone footage, the decoder yields nothing for the first
# few frames. The proxy (and so the preview) must still have a picture from the very start.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=3840x2160:rate=30:duration=1.5' -c:v libx265 -pix_fmt yuv420p -x265-params 'bframes=4:open-gop=1:keyint=15:log-level=error' -tag:v hvc1 TestArtifacts/fixtures/lead4k-source.mp4
ffmpeg -hide_banner -loglevel error -y -ss 0.4 -i TestArtifacts/fixtures/lead4k-source.mp4 -c copy TestArtifacts/fixtures/lead4k.mp4
rm -f TestArtifacts/fixtures/hlg4k-landscape.mov TestArtifacts/fixtures/lead4k-source.mp4
# Larger-than-FHD sources a plain HEVC proxy cannot stand in for; each must be previewed from the
# original: BT.470BG colour tags (the writer has no constant for them and would raise), an alpha
# channel, and non-square pixels.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=2560x1440:rate=30:duration=0.4' -vf setparams=color_primaries=bt470bg:color_trc=smpte170m:colorspace=bt470bg -c:v libx264 -pix_fmt yuv420p -x264-params colorprim=bt470bg:transfer=smpte170m:colormatrix=bt470bg TestArtifacts/fixtures/bt470bg-1440.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=2560x1440:rate=30:duration=0.2,format=yuva444p10le' -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le TestArtifacts/fixtures/alpha-1440.mov
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=2560x1440:rate=30:duration=0.4' -vf setsar=4/3 -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 TestArtifacts/fixtures/anamorphic-1440.mp4
