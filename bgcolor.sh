#!/usr/bin/env bash
# bgcolor.sh - set this terminal's background color (Linux/macOS).
#
#   bgcolor              show the numbered list
#   bgcolor 12           set background to color 12
#   bgcolor 336699       set background to any hex color (NO leading #)
#   bgcolor teal         set background by name
#   bgcolor set 12 1A2B3C   permanently redefine color 12 in the list
#   bgcolor /h           help
#
# Linux counterpart of bgcolor.ps1. The Windows version rewrites a conhost
# palette slot through Win32; there is no such thing here. Instead this emits
# OSC 11 ("set default background", ESC ] 11 ; <color> BEL), which every modern
# terminal emulator honors: xterm, gnome-terminal/vte, kitty, alacritty,
# wezterm, foot, Windows Terminal, iTerm2. The change lasts until the terminal
# is reset or the window closes, exactly like the Windows one.
#
# Every color in the list is dark enough that white text stays readable. This
# does not touch any terminal profile or config file; it only speaks to the
# running terminal.

set -uo pipefail

# ---------------------------------------------------------------------
# THE LIST. The number on the left is what you type: bgcolor 12
# Order is significant and 1-based. Edit here, or: bgcolor set <N> <RRGGBB>
# Stored as "name:RRGGBB" so `set` can rewrite one line safely.
# ---------------------------------------------------------------------
COLORS=(
    "green:003000"
    "blue:012456"
    "purple:400040"
    "charcoal:202020"
    "olive:504000"
    "wine:4A1020"
    "teal:063038"
    "rust:4A2408"
    "indigo:201050"
    "forest:0D3018"
    "magenta:3A0A30"
    "slate:1E2A38"
    "brown:302010"
    "navy:0B1B3A"
    "midnight:0A0F1E"
    "black:0C0C0C"
)

name_of() { printf '%s' "${COLORS[$1]%%:*}"; }   # 0-based index -> name
hex_of()  { printf '%s' "${COLORS[$1]##*:}"; }   # 0-based index -> RRGGBB

pick="${1:-}"

show_help() {
    cat <<'EOF'
bgcolor - change this terminal's background color

SETTING A COLOR (run inside the window you want to change):
  bgcolor            show the numbered list
  bgcolor 12         set background to color 12 from that list
  bgcolor 336699     set background to any hex color you like
  bgcolor teal       set background by name
  bgcolor set 12 1A2B3C
                     permanently change what color 12 is in the list
  bgcolor /h         this help

THESE WILL NOT WORK - and this is probably what bit you:
  bgcolor #003366          <-- WRONG in bash. Prints the list and nothing else.
  bgcolor set 16 #000000   <-- WRONG. Complains the hex is missing.

  Why: bash treats a word that begins with # as the start of a comment and
  throws away the rest of the line BEFORE this script ever runs, so the script
  genuinely receives nothing. It cannot be fixed here; the color is gone before
  the program starts.

  Do this instead - drop the # entirely:
  bgcolor 003366
  bgcolor set 16 000000

  Or quote it, which also works:
  bgcolor '#003366'
  bgcolor set 16 '#000000'

NOTES:
  The list is this script's own menu and persists forever. It does not touch
  your terminal profile, so nothing here can damage your normal colors.
  A background change lasts until the terminal is reset or the window closes.
  Over tmux/screen the escape is wrapped so it reaches the real terminal; if
  your tmux is old you may need "set -g allow-passthrough on".

TO UNDO: bgcolor 16 (near-black default), or close the window, or: reset
EOF
}

# Emit OSC 11 with the given #RRGGBB, wrapping for tmux/screen passthrough so it
# reaches the outer terminal rather than being swallowed by the multiplexer.
set_bg() {
    local hex="$1" osc
    osc=$'\e]11;#'"$hex"$'\a'
    if [[ -n "${TMUX:-}" ]]; then
        # tmux DCS passthrough: ESC P tmux ; <ESC-doubled payload> ESC \
        local inner="${osc//$'\e'/$'\e\e'}"
        printf '\ePtmux;%s\e\\' "$inner"
    elif [[ "${TERM:-}" == screen* ]]; then
        local inner="${osc//$'\e'/$'\e\e'}"
        printf '\eP%s\e\\' "$inner"
    else
        printf '%s' "$osc"
    fi
}

# Best-effort query of the terminal's current background, for the "<-- current"
# marker. Any hiccup (no tty, no reply, unusual format) just skips the marker.
current_bg_hex() {
    [[ -t 0 && -t 1 ]] || return 1
    command -v stty >/dev/null 2>&1 || return 1
    local old reply
    old=$(stty -g 2>/dev/null) || return 1
    stty raw -echo min 0 time 0 2>/dev/null || { stty "$old" 2>/dev/null; return 1; }
    printf '\e]11;?\a' > /dev/tty
    IFS= read -r -d $'\a' -t 1 reply < /dev/tty 2>/dev/null
    stty "$old" 2>/dev/null
    # reply looks like: ESC]11;rgb:rrrr/gggg/bbbb   (16-bit channels)
    if [[ "$reply" =~ rgb:([0-9A-Fa-f]+)/([0-9A-Fa-f]+)/([0-9A-Fa-f]+) ]]; then
        printf '%02X%02X%02X' \
            "$((16#${BASH_REMATCH[1]:0:2}))" \
            "$((16#${BASH_REMATCH[2]:0:2}))" \
            "$((16#${BASH_REMATCH[3]:0:2}))"
        return 0
    fi
    return 1
}

# ---- help ----
if [[ "$pick" =~ ^(/h|/\?|-h|--help|help)$ ]]; then
    show_help
    exit 0
fi

# ---- no arguments: show the list ----
if [[ -z "$pick" ]]; then
    cur=""
    cur=$(current_bg_hex) || cur=""
    echo
    for i in "${!COLORS[@]}"; do
        nm=$(name_of "$i"); hx=$(hex_of "$i")
        mark=""
        [[ -n "$cur" && "${hx^^}" == "${cur^^}" ]] && mark="   <-- current"
        printf '  %2d   #%s   %s%s\n' "$((i + 1))" "${hx^^}" "$nm" "$mark"
    done
    echo
    echo "  bgcolor 12       set background to number 12"
    echo "  bgcolor 336699   any hex, NO leading # (bash deletes it)"
    echo "  bgcolor /h       more"
    exit 0
fi

# ---- set: permanently redefine an entry in the list above ----
if [[ "$pick" == "set" ]]; then
    slot="${2:-}"; new_hex="${3:-}"
    if [[ -z "$new_hex" ]]; then
        echo "No hex color received."
        echo "bash treats a leading # as a comment, so the color was thrown away"
        echo "before this script ran. Drop the # entirely:"
        echo "  bgcolor set ${slot:-<N>} 336699"
        exit 1
    fi
    if ! [[ "$slot" =~ ^[0-9]+$ ]] || (( slot < 1 || slot > ${#COLORS[@]} )) \
       || ! [[ "$new_hex" =~ ^#?([0-9A-Fa-f]{6})$ ]]; then
        printf 'Usage: bgcolor set <1..%d> <RRGGBB>\n' "${#COLORS[@]}"
        exit 1
    fi
    hex="${BASH_REMATCH[1]^^}"
    name=$(name_of "$((slot - 1))")
    self="${BASH_SOURCE[0]}"
    # Rewrite exactly the one list line: "name:OLDHEX" -> "name:NEWHEX".
    pattern="^(\s*\"${name}:)[0-9A-Fa-f]{6}(\")"
    if ! grep -Eq "$pattern" "$self"; then
        echo "Could not find entry $slot ($name) in the list to update."
        exit 1
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/bgcolor.XXXXXX")" || { echo "Could not create a temp file."; exit 1; }
    sed -E "s/${pattern}/\1${hex}\2/" "$self" > "$tmp"
    # Validate before committing, so a bad write cannot break the tool.
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "Refusing to write: that edit would break the script."
        exit 1
    fi
    cat "$tmp" > "$self"      # preserve inode/perms; do not mv across the symlink shim
    rm -f "$tmp"
    echo "color $slot is now #$hex  [permanent]"
    echo "Run 'bgcolor $slot' to apply it."
    exit 0
fi

# ---- resolve what the user asked for ----
new_hex=""
pick_lower="${pick,,}"
if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#COLORS[@]} )); then
    new_hex=$(hex_of "$((pick - 1))")
elif [[ "$pick" =~ ^#?([0-9A-Fa-f]{6})$ ]]; then
    new_hex="${BASH_REMATCH[1]}"
else
    # name lookup
    for i in "${!COLORS[@]}"; do
        if [[ "$(name_of "$i")" == "$pick_lower" ]]; then new_hex=$(hex_of "$i"); break; fi
    done
fi

if [[ -z "$new_hex" ]]; then
    echo "Unrecognised argument: $pick"
    echo "Try:  bgcolor          (show the list)"
    echo "      bgcolor 12       (a number from the list)"
    echo "      bgcolor 336699   (hex, NO leading #)"
    exit 1
fi

new_hex="${new_hex^^}"
set_bg "$new_hex"
printf 'background -> #%s\n' "$new_hex"
