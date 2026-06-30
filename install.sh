#!/bin/bash
# Install mplay.
#
# Scripts and generic configs are SYMLINKED from this repo into ~/.local/bin and
# ~/.config, so the repo is the single source of truth — editing a file here
# edits the installed command, and there is only ever one copy. Machine-specific
# files (mplay.conf, artist-aliases.conf) are COPIED from their .example once and
# then left alone for you to edit. The CoreAudio sample-rate helper is compiled.
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
CFG="$HOME/.config"

mkdir -p "$BIN" "$CFG/mplay" "$CFG/ncmpcpp"

# 1. Symlink every bash script (single source of truth).
for f in "$REPO"/bin/mplay*; do
    ln -sf "$f" "$BIN/$(basename "$f")"
done

# 2. Compile the sample-rate matcher helper (needs the Xcode command-line tools).
if command -v swiftc >/dev/null; then
    swiftc -O "$REPO/src/mplay-srate.swift" -o "$BIN/mplay-srate"
else
    echo "warning: swiftc not found — skipping mplay-srate (run: xcode-select --install)"
fi

# 3. Symlink generic configs.
ln -sf "$REPO/config/mplay/tmux.conf"      "$CFG/mplay/tmux.conf"
ln -sf "$REPO/config/ncmpcpp/config"       "$CFG/ncmpcpp/config"
ln -sf "$REPO/config/ncmpcpp/bindings"     "$CFG/ncmpcpp/bindings"
ln -sf "$REPO/config/ncmpcpp/cover.sh"     "$CFG/ncmpcpp/cover.sh"

# 4. Seed machine-specific configs from templates (copy once, never overwrite).
seed() {  # seed <example> <dest>
    if [ ! -e "$2" ]; then
        cp "$1" "$2"
        echo "created $2 — edit it for your setup."
    fi
}
seed "$REPO/config/mplay/mplay.conf.example"          "$CFG/mplay/mplay.conf"
seed "$REPO/config/mplay/artist-aliases.conf.example" "$CFG/mplay/artist-aliases.conf"

echo "installed."
echo "deps: brew install mpd mpc ncmpcpp fzf tmux chafa ffmpeg"
echo "next: edit ~/.config/mplay/mplay.conf, then run: mplay"
