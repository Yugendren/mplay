#!/bin/bash
# Extract and display album art in Ghostty/Kitty-compatible terminals
MUSIC_DIR="$HOME/Music/flac-library"
COVER_PATH="/tmp/ncmpcpp_cover.jpg"

# Get current song path from mpd
SONG=$(mpc current -f "%file%")
[ -z "$SONG" ] && exit 0

SONG_DIR="$MUSIC_DIR/$(dirname "$SONG")"

# Try to extract embedded art first
ffmpeg -y -i "$MUSIC_DIR/$SONG" -an -vcodec mjpeg -q:v 2 "$COVER_PATH" 2>/dev/null

# If no embedded art, look for cover files in the folder
if [ ! -s "$COVER_PATH" ]; then
    for img in "$SONG_DIR"/cover.{jpg,png,jpeg} "$SONG_DIR"/folder.{jpg,png,jpeg} "$SONG_DIR"/front.{jpg,png,jpeg} "$SONG_DIR"/*.{jpg,png,jpeg}; do
        if [ -f "$img" ]; then
            cp "$img" "$COVER_PATH"
            break
        fi
    done
fi
