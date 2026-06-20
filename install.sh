#!/bin/bash
# Install mplay: copy scripts into ~/.local/bin and configs into ~/.config.
# Re-running is safe — existing files are overwritten.
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
CFG="$HOME/.config"

mkdir -p "$BIN" "$CFG/mplay" "$CFG/ncmpcpp"

install -m 755 "$REPO"/bin/mplay*       "$BIN/"
install -m 644 "$REPO"/config/mplay/*    "$CFG/mplay/"
install -m 644 "$REPO"/config/ncmpcpp/*  "$CFG/ncmpcpp/"

echo "installed."
echo "deps: brew install mpd mpc ncmpcpp fzf tmux chafa ffmpeg"
