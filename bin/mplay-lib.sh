#!/bin/bash
# Shared library for mplay-sync (whole library) and mplay-add (selected folders).
# This file is SOURCED, not executed — it defines constants + functions only.
# The unit of work is one "top-level folder" under $DOWNLOADS; process_top_dir()
# applies all organizing logic (tags > folder names, disc collapse, aliases,
# artist-discography detection, cover art) and is idempotent (skips already-linked).

# Machine-specific values (library path, SMB share, etc.) live in mplay.conf,
# which is NOT committed to git. Copy mplay.conf.example -> ~/.config/mplay/mplay.conf
# (install.sh does this for you) and edit it for your setup.
MPLAY_CONF="${MPLAY_CONF:-$HOME/.config/mplay/mplay.conf}"
if [ -f "$MPLAY_CONF" ]; then
    # shellcheck source=/dev/null
    . "$MPLAY_CONF"
else
    echo "mplay: missing $MPLAY_CONF — copy mplay.conf.example there and edit it." >&2
    exit 1
fi

# Defaults for anything the config didn't set.
LIBRARY="${LIBRARY:-$HOME/Music/flac-library}"
ARTIST_ALIASES="${ARTIST_ALIASES:-$HOME/.config/mplay/artist-aliases.conf}"

# Audio extensions we care about (ERE — used with `find -E`)
AUDIO_EXTS='\.(flac|mp3|m4a|opus|ogg|wav|aac)$'

# Block obvious non-music release names (last-resort safety net).
# Overridable via BLOCK_RE in mplay.conf.
BLOCK_RE="${BLOCK_RE:-(WEB-DL|BDRip|BluRay|HEVC|x265|x264|1080p|2160p)}"

# Ensure the SMB share is mounted. Returns 0 if available, 1 otherwise.
ensure_mounted() {
    [ -d "$DOWNLOADS" ] && return 0
    osascript -e "mount volume \"$REMOTE_SMB\"" >/dev/null 2>&1
    local i
    for i in {1..10}; do
        [ -d "$DOWNLOADS" ] && return 0
        sleep 1
    done
    [ -d "$DOWNLOADS" ]
}

# Tell mpd to rescan, if it's running. Pass --wait to block until done.
mpd_update() {
    pgrep -x mpd >/dev/null || return 0
    mpc update "$@" >/dev/null 2>&1
}

# Snapshot every source path already linked into the library, ONCE, as a
# newline-delimited string. process_top_dir then subtracts this set from a
# folder's file list in a single `grep -Fxv` (C, fast) instead of doing a
# filesystem walk or bash scan per file. Callers MUST run this before processing.
# (bash 3.2 has no associative arrays, hence a plain string rather than a hash.)
LINKED_INDEX=""
LINKED_INDEX_SORTED=""
build_linked_index() {
    LINKED_INDEX="$(find "$LIBRARY" -type l -exec readlink {} + 2>/dev/null)"
    # Pre-sort once (LC_ALL=C) so each folder can be subtracted with a linear
    # `comm` merge instead of rebuilding a big grep automaton per folder.
    LINKED_INDEX_SORTED="$(printf '%s\n' "$LINKED_INDEX" | LC_ALL=C sort)"
}

# Strip release-junk: leading [date], trailing [FLAC...], (year), "Discography", etc.
clean_name() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    # leading bracket groups: [2024.07.10], [Nemuri], [FLAC ...], [BDRip ...]
    s=$(printf '%s' "$s" | sed -E 's/^\[[^]]*\][[:space:]]*//g')
    # everything from a format-marker [FLAC] / [MP3] / [ALAC] onwards
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]*\[(FLAC|MP3|ALAC|AAC|WAV|24bit|16bit|HiRes|Hi-Res)[^]]*\].*$//I')
    # bare format markers without brackets (… FLAC 88, … FLAC vtwin88cube)
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+(FLAC|MP3|ALAC)[[:space:]].*$//I')
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+(FLAC|MP3|ALAC)$//I')
    # any remaining trailing bracket groups (must run BEFORE the discography strip
    # so "MYTH & ROID [Complete Discography]" loses the whole bracket as a unit)
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]*\[[^]]*\][[:space:]]*$//g')
    # everything from " - Discography" / " Discography" onwards is junk
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]*[-—–]?[[:space:]]*[Dd]iscography.*$//')
    # trailing year-range parens (2007-2026), (1985)
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]*\([0-9]{4}(-[0-9]{4})?\)[[:space:]]*$//')
    # trailing all-ASCII parens — e.g. "ヨルシカ (Yorushika)" — strip the romanization
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]*\([A-Za-z][A-Za-z0-9 .'\''&-]*\)[[:space:]]*$//')
    # known release-group trailing tags
    s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+(vtwin88cube|88|RGD_TheBest)[[:space:]]*$//I')
    # sanitize slashes
    s=$(printf '%s' "$s" | tr '/' '-')
    # final trim
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_disc_dir() {
    [[ "$1" =~ ^([Cc][Dd]|[Dd][Ii]([Ss][Kk]|[Ss][Cc]))[[:space:]]?[0-9]+$ ]]
}

# Artist-discography folder detector: true if `dir` has ≥2 non-disc subdirs
# that each contain at least one audio file.
is_artist_folder() {
    local dir="$1"
    [ ! -d "$dir" ] && return 1
    local count=0
    while IFS= read -r -d '' sub; do
        local subname
        subname=$(basename "$sub")
        is_disc_dir "$subname" && continue
        if find -E "$sub" -type f -iregex ".*${AUDIO_EXTS}" -print -quit 2>/dev/null | grep -q .; then
            count=$((count + 1))
            [ "$count" -ge 2 ] && return 0
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    return 1
}

# Artist aliases: "Wrong Name = Canonical" lines. Comments with #.
apply_alias() {
    local artist="$1"
    [ ! -f "$ARTIST_ALIASES" ] && { printf '%s' "$artist"; return; }
    local lhs rhs line
    while IFS= read -r line; do
        # strip comments and blanks
        line="${line%%#*}"
        [ -z "${line// }" ] && continue
        lhs="${line%%=*}"
        rhs="${line#*=}"
        lhs="$(echo "$lhs" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        rhs="$(echo "$rhs" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [ "$(printf '%s' "$artist" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$lhs" | tr '[:upper:]' '[:lower:]')" ]; then
            printf '%s' "$rhs"
            return
        fi
    done < "$ARTIST_ALIASES"
    printf '%s' "$artist"
}

# Process ONE top-level folder: link every audio file under it into
# $LIBRARY/$ARTIST/$ALBUM/, plus cover art. Idempotent.
process_top_dir() {
    local top="$1"
    local base
    base=$(basename "$top")

    if [[ "$base" =~ $BLOCK_RE ]]; then
        # only skip if it contains no audio files at all (don't drop legit FLAC releases bracketed with stray words)
        if ! find -E "$top" -type f -iregex ".*${AUDIO_EXTS}" -print -quit | grep -q .; then
            return 0
        fi
    fi

    # Folder-first rule: if the top-level dir is itself an artist discography
    # (≥2 album subdirs with audio), pin every file under it to that artist.
    local TOP_IS_ARTIST=no
    local TOP_ARTIST=""
    if is_artist_folder "$top"; then
        TOP_IS_ARTIST=yes
        TOP_ARTIST=$(clean_name "$base")
    fi

    # Subtract already-linked paths up front with a single grep, so the per-file
    # loop below only runs for genuinely new files. `-x` makes the empty-index
    # case (fresh library) correctly treat every file as new. NOTE: this is
    # line-based, so it assumes no audio filename contains a literal newline.
    while IFS= read -r audio_file; do
        [ -z "$audio_file" ] && continue
        local FILENAME
        FILENAME=$(basename "$audio_file")

        # ffprobe outputs tags in file-order, not request-order — parse by key
        local METADATA
        METADATA=$(ffprobe -v quiet -show_entries format_tags -of default=noprint_wrappers=1 "$audio_file" 2>/dev/null)
        get_tag() {
            printf '%s\n' "$METADATA" | grep -i "^TAG:$1=" | head -1 | cut -d= -f2- | tr '/' '-' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
        }
        local TITLE ARTIST ALBUM ALBUM_ARTIST DISC
        TITLE=$(get_tag title)
        ARTIST=$(get_tag artist)
        ALBUM=$(get_tag album)
        ALBUM_ARTIST=$(get_tag album_artist)
        DISC=$(get_tag disc | sed 's|/.*||' | tr -dc '0-9')

        [ -n "$ALBUM_ARTIST" ] && ARTIST="$ALBUM_ARTIST"

        # Walk parents: file -> parent -> grandparent (within DOWNLOADS)
        local PARENT_DIR PARENT GRAND_DIR GRAND
        PARENT_DIR=$(dirname "$audio_file")
        PARENT=$(basename "$PARENT_DIR")
        GRAND_DIR=$(dirname "$PARENT_DIR")
        GRAND=$(basename "$GRAND_DIR")

        # Collapse disc subfolder: CD1 -> use grandparent as the album dir, capture disc num
        if is_disc_dir "$PARENT"; then
            local disc_num
            disc_num=$(printf '%s' "$PARENT" | tr -dc '0-9')
            [ -z "$DISC" ] && DISC="$disc_num"
            PARENT="$GRAND"
            GRAND_DIR=$(dirname "$GRAND_DIR")
            GRAND=$(basename "$GRAND_DIR")
        fi

        local CLEAN_PARENT CLEAN_GRAND
        CLEAN_PARENT=$(clean_name "$PARENT")
        CLEAN_GRAND=$(clean_name "$GRAND")

        # Fallbacks: tag > folder
        if [ -z "$ALBUM" ]; then
            ALBUM="$CLEAN_PARENT"
        fi
        if [ -z "$ARTIST" ]; then
            if [ "$GRAND_DIR" != "$DOWNLOADS" ] && [ -n "$CLEAN_GRAND" ]; then
                ARTIST="$CLEAN_GRAND"
            else
                ARTIST="Unknown Artist"
            fi
        fi
        [ -z "$ALBUM" ] && ALBUM="Unknown Album"

        # Folder-first override: if the top-level dir is an artist discography,
        # the artist is the folder, regardless of what tags say (collabs land here too).
        if [ "$TOP_IS_ARTIST" = "yes" ] && [ -n "$TOP_ARTIST" ]; then
            ARTIST="$TOP_ARTIST"
        fi

        # Alias normalization ("Jay-Z & Linkin Park = Linkin Park" etc.)
        ARTIST=$(apply_alias "$ARTIST")

        local TARGET_DIR="$LIBRARY/$ARTIST/$ALBUM"
        mkdir -p "$TARGET_DIR"

        # Prepend disc number to track name if we have one and it's not already there
        local TARGET_NAME="$FILENAME"
        if [ -n "$DISC" ] && [ "$DISC" -gt 0 ] 2>/dev/null; then
            if [[ ! "$FILENAME" =~ ^${DISC}[-.] ]] && [[ ! "$FILENAME" =~ ^[Dd]isc?${DISC} ]]; then
                TARGET_NAME="${DISC}-${FILENAME}"
            fi
        fi

        if [ ! -e "$TARGET_DIR/$TARGET_NAME" ] && [ ! -L "$TARGET_DIR/$TARGET_NAME" ]; then
            ln -s "$audio_file" "$TARGET_DIR/$TARGET_NAME"
        fi

        # Cover art: link first image from original folder if none present yet
        if ! ls "$TARGET_DIR"/*.jpg "$TARGET_DIR"/*.png "$TARGET_DIR"/*.jpeg 2>/dev/null | grep -q .; then
            find "$PARENT_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.jpeg" \) -print0 |
                while IFS= read -r -d '' img; do
                    local IMG_NAME
                    IMG_NAME=$(basename "$img")
                    [ ! -e "$TARGET_DIR/$IMG_NAME" ] && ln -s "$img" "$TARGET_DIR/$IMG_NAME"
                done
        fi
    done < <(find -E "$top" -type f -iregex ".*${AUDIO_EXTS}" 2>/dev/null \
                | LC_ALL=C sort \
                | LC_ALL=C comm -23 - <(printf '%s\n' "$LINKED_INDEX_SORTED"))
}
