# mplay

> A tmux music player for macOS: mpd + ncmpcpp with live cover art, fuzzy search, and automatic DAC sample-rate matching.

A small Bash suite that turns [`mpd`](https://www.musicpd.org/) +
[`ncmpcpp`](https://github.com/ncmpcpp/ncmpcpp) into a single, tmux-based music
player for macOS: ncmpcpp on the left, live cover art on the right, a fuzzy
track search, a command palette, playlist helpers, a library ingester, and a
sample-rate matcher that keeps your DAC bit-perfect.

```
┌───────────────────────────┬──────────────────────┐
│  ncmpcpp                   │                      │
│  (queue / library / etc.)  │      cover art       │
│                            │                      │
└───────────────────────────┴──────────────────────┘
        /  search    :  commands    ?  help
```

## Features

- **One command.** `mplay` starts `mpd` (if needed) and opens the tmux split,
  on its own tmux socket so it never touches your normal tmux sessions.
- **Sample-rate matching.** A background daemon reads each track's sample rate
  and sets the current default output device to match, so CoreAudio stops
  resampling. See [Bit-perfect notes](#bit-perfect-notes).
- **Library ingester.** `mplay-sync` builds a clean `Artist/Album/` symlink tree
  from a messy downloads folder (tags first, folder names as fallback; handles
  multi-disc, discographies, artist aliases, cover art). `mplay-add` does one
  folder; `mplay-clean` repairs an existing library.
- **Fuzzy search (`/`)**, **command palette (`:`)**, **help (`?`)** — all as
  tmux popups. Playlist save/load/append/delete via `mplay-playlist`.

## Dependencies

```sh
brew install mpd mpc ncmpcpp fzf tmux chafa ffmpeg
```

`mplay-srate` (the sample-rate helper) is compiled with `swiftc`, which ships
with the Xcode command-line tools (`xcode-select --install`).

## Install

```sh
git clone https://github.com/Yugendren/mplay.git
cd mplay
./install.sh
mplay
```

That's it — **no config editing required.** On first launch `mplay` runs a
one-time setup wizard that asks (with a fuzzy folder picker) where your music
lives, then writes everything for you:

```
┌─ mplay setup ─────────────────────────────────────────┐
│  Where is your music library?                          │
│  > flac                                                │
│    /Users/you/Music/flac-library      ◀ type, ↵ select │
└────────────────────────────────────────────────────────┘
```

It generates `~/.config/mplay/mplay.conf`, `~/.mpd/mpd.conf` (CoreAudio output),
and `~/.config/ncmpcpp/config` — all pointed at the folder you picked. Your
answers are saved permanently; re-run the wizard any time with `mplay --setup`.

`install.sh` itself just **symlinks** the scripts and path-independent configs
into `~/.local/bin` and `~/.config` (the repo stays the single source of truth —
edit a file here and the installed command changes) and compiles `mplay-srate`.

> Scriptable / headless: `mplay-setup --library ~/Music [--downloads DIR] [--smb smb://user@host/share]`

## Configuration

`~/.config/mplay/mplay.conf` (written by the setup wizard, **not** tracked by
git) holds everything machine-specific. You rarely need to touch it by hand:

| Variable        | Meaning                                                        |
|-----------------|----------------------------------------------------------------|
| `LIBRARY`       | Local library mpd indexes (must match `music_directory`).      |
| `DOWNLOADS`     | Source folder `mplay-sync` ingests from.                       |
| `REMOTE_SMB`    | Share to auto-mount if `DOWNLOADS` is missing (empty = off).   |
| `ARTIST_ALIASES`| Path to the artist-alias table.                                |
| `BLOCK_RE`      | Optional ERE of non-music release names to skip.               |

## Keys

| Key | Action |
|-----|--------|
| `/` | fuzzy track search over the whole library |
| `:` | command palette (playlists, playback, queue) |
| `?` | this cheatsheet |
| `space` / `enter` | add to queue / play |
| `P` | pause/resume · `>` `<` next/prev · `+` `-` volume |
| `r` / `R` | toggle random / repeat |
| `q` | quit mplay |

## Bit-perfect notes

`mplay-audiomatch` watches `mpc idle player` and, on each track change, sets the
**current default output device's** nominal sample rate to the track's rate via
`mplay-srate`. This is the meaningful fix for the common "everything plays at 48
kHz" resampling problem, and it works in normal (shared) mode.

`mplay-srate` also makes a **best-effort** attempt to raise the device's
physical format to the highest bit depth it offers at that rate (prefer 32-bit
over 24/16). Many devices reject a physical-format change in shared mode, in
which case only the sample rate is matched. Truly bit-perfect, no-mixing output
(integer/hog mode) is out of scope for this tool.

## Layout

```
bin/             scripts (symlinked into ~/.local/bin)
  mplay              launcher (mpd + tmux split)
  mplay-art          cover-art pane
  mplay-audiomatch   sample-rate matcher daemon
  mplay-sync/add/clean   library ingest + repair
  mplay-find/cmd/playlist/help   search, palette, playlists, help
  mplay-lib.sh       shared functions (sourced)
src/
  mplay-srate.swift  CoreAudio sample-rate/bit-depth setter (compiled)
config/
  mplay/             tmux.conf + *.example templates
  ncmpcpp/           ncmpcpp config, bindings, cover.sh
install.sh
```
