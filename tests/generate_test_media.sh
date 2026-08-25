#!/bin/bash
# Generate deterministic 10-second test MKV with perfectly aligned timestamps
# Includes: 
# - Video (30fps, 10 seconds)
# - Audio (Sine wave, 10 seconds)
# - SRT Subtitles (Track 1)
# - ASS Subtitles (Track 2)

OUTPUT="test_sync.mkv"

if [ -f "$OUTPUT" ]; then
    echo "Found existing $OUTPUT, removing..."
    rm "$OUTPUT"
fi

echo "Creating synthetic SRT subtitle..."
cat << 'EOF' > test.srt
1
00:00:01,000 --> 00:00:03,000
SRT: 1.0s to 3.0s

2
00:00:05,000 --> 00:00:07,000
SRT: 5.0s to 7.0s
EOF

echo "Creating synthetic ASS subtitle..."
cat << 'EOF' > test.ass
[Script Info]
ScriptType: v4.00+
PlayResX: 384
PlayResY: 288

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,16,&Hffffff,&Hffffff,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,ASS: 1.0s to 3.0s
Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,ASS: 5.0s to 7.0s
EOF

echo "Generating and muxing $OUTPUT..."
# testsrc generates a 10s video with a rolling timestamp
# aevalsrc generates a 10s sine wave audio (1000Hz)
ffmpeg -v error -y \
  -f lavfi -i testsrc=duration=10:size=640x360:rate=30 \
  -f lavfi -i aevalsrc="sin(1000*2*PI*t)":duration=10:sample_rate=48000 \
  -i test.srt \
  -i test.ass \
  -map 0:v -map 1:a -map 2:s -map 3:s \
  -c:v libx264 -preset ultrafast \
  -c:a aac -b:a 192k \
  -c:s:0 srt \
  -c:s:1 ass \
  -metadata:s:s:0 title="English SRT" \
  -metadata:s:s:1 title="Hebrew ASS" \
  "$OUTPUT"

echo "Generating and muxing test_subs.mp4..."
ffmpeg -v error -y \
  -f lavfi -i testsrc=duration=10:size=640x360:rate=30 \
  -f lavfi -i aevalsrc="sin(1000*2*PI*t)":duration=10:sample_rate=48000 \
  -i test.srt \
  -map 0:v -map 1:a -map 2:s \
  -c:v libx264 -preset ultrafast \
  -c:a aac -b:a 192k \
  -c:s mov_text \
  -metadata:s:s:0 title="English MP4" \
  "test_subs.mp4"

rm test.srt test.ass
echo "Generated $OUTPUT and test_subs.mp4 successfully."
