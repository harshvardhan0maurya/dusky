#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Hyprlock Manager v4.2.1
# -----------------------------------------------------------------------------
# Source A: Dusky TUI Engine v3.3.2 (Rendering, Input, Safety)
# Source B: Hyprlock Theme Manager v2.0.0 (Logic, Discovery)
#
# FEATURES:
#   - Pure Theme Switching (No tabs)
#   - Tilde (~) Path Preservation
#   - Full Vim/Arrow/Page Navigation
#   - Configurable Mouse Hitbox
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# ▼ USER CONFIGURATION ▼
# =============================================================================

# Paths
readonly HYPR_DIR="${HOME}/.config/hypr"
readonly CONFIG_FILE="${HYPR_DIR}/hyprlock.conf"
readonly THEMES_DIR="${HYPR_DIR}/hyprlock_themes"

# UI Settings
readonly APP_TITLE="Dusky Hyprlock Manager"
readonly APP_VERSION="v4.2.1"

# Dimensions
declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=80
declare -ri ITEM_PADDING=50
declare -ri HEADER_ROWS=4
# FIX: Adjusted start row calculation to match visual layout
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

# MOUSE CONTROL
# 82 = Full width. Set to ~38 to restrict clicks to the text area.
declare -ri MOUSE_HITBOX_LIMIT=82

# =============================================================================
# ▲ END USER CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

readonly ESC_READ_TIMEOUT=0.05

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare -i PREVIEW_ENABLED=0
declare ORIGINAL_STTY=""

# --- Data Structures ---
declare -a THEME_LIST=()
declare -A THEME_PATHS=()
declare ACTIVE_THEME=""

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Regex Helpers (v3.3.2) ---

escape_sed_replacement() {
    local _esc_input=$1
    local -n _esc_out_ref=$2
    _esc_input=${_esc_input//\\/\\\\}
    _esc_input=${_esc_input//|/\\|}
    _esc_input=${_esc_input//&/\\&}
    _esc_input=${_esc_input//$'\n'/\\n}
    _esc_out_ref=$_esc_input
}

# --- Initialization & Logic ---

init_themes() {
    # Discovery Logic
    local config_file dir name
    THEME_LIST=()
    
    if [[ ! -d "$THEMES_DIR" ]]; then
        return
    fi

    while IFS= read -r -d '' config_file; do
        dir="${config_file%/*}"
        name=""
        if [[ -f "${dir}/theme.json" ]] && command -v jq &>/dev/null; then
            name=$(jq -r '.name // empty' "${dir}/theme.json" 2>/dev/null) || true
        fi
        [[ -z "$name" ]] && name="${dir##*/}"

        THEME_LIST+=("$name")
        THEME_PATHS["$name"]="$dir"
    done < <(find "$THEMES_DIR" -mindepth 2 -maxdepth 2 -name "hyprlock.conf" -print0 | sort -z)
}

detect_active_theme() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    local line source_path resolved_path
    source_path=$(grep '^[[:space:]]*source[[:space:]]*=' "$CONFIG_FILE" | head -n1 | cut -d'=' -f2-)
    
    source_path="${source_path#"${source_path%%[![:space:]]*}"}"
    source_path="${source_path%"${source_path##*[![:space:]]}"}"

    if [[ "$source_path" == "~"* ]]; then
        resolved_path="${HOME}${source_path:1}"
    else
        resolved_path="$source_path"
    fi

    local name path
    ACTIVE_THEME=""
    for name in "${THEME_LIST[@]}"; do
        path="${THEME_PATHS[$name]}/hyprlock.conf"
        if [[ "$path" == "$resolved_path" ]]; then
            ACTIVE_THEME="$name"
            return
        fi
    done
}

apply_theme() {
    local theme_name=$1
    local theme_dir="${THEME_PATHS[$theme_name]:-}"
    [[ -z "$theme_dir" ]] && return

    local source_path="${theme_dir}/hyprlock.conf"
    if [[ ! -r "$source_path" ]]; then return; fi

    local tilde_path="${source_path/#"$HOME"/\~}"
    local safe_path
    escape_sed_replacement "$tilde_path" safe_path
    
    sed --follow-symlinks -i \
        "s|^\([[:space:]]*source[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_path}|" \
        "$CONFIG_FILE"
        
    ACTIVE_THEME="$theme_name"
}

# --- UI Rendering (v3.3.2 Engine) ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item display
    local -i i count visible_start visible_end rows_rendered
    local -i visible_len left_pad right_pad

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))
    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    buf+="${C_MAGENTA}├${H_LINE}┤${C_RESET}"$'\n'

    count=${#THEME_LIST[@]}

    if (( count == 0 )); then SELECTED_ROW=0; SCROLL_OFFSET=0;
    else
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
        if (( SELECTED_ROW < SCROLL_OFFSET )); then SCROLL_OFFSET=$SELECTED_ROW;
        elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 )); fi
        local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
        (( max_scroll < 0 )) && max_scroll=0
        (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    if (( SCROLL_OFFSET > 0 )); then buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n';
    else buf+="${CLR_EOL}"$'\n'; fi

    for (( i = visible_start; i < visible_end; i++ )); do
        item=${THEME_LIST[i]}
        if [[ "$item" == "$ACTIVE_THEME" ]]; then
            display="${C_GREEN}● ACTIVE${C_RESET}"
        else
            display="${C_GREY}○${C_RESET}"
        fi

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:${ITEM_PADDING}}"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} ${display}${CLR_EOL}"$'\n'
        fi
    done

    rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do buf+="${CLR_EOL}"$'\n'; done

    if (( count > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        if (( visible_end < count )); then buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n';
        else buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'; fi
    else buf+="${CLR_EOL}"$'\n'; fi

    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'
    buf+="${C_CYAN} [Ent] Apply  [p] Preview  [j/k] Nav  [g/G] Top/Bot  [q] Quit${C_RESET}"$'\n'

    if (( PREVIEW_ENABLED )); then
        local theme_name=${THEME_LIST[SELECTED_ROW]}
        local conf="${THEME_PATHS[$theme_name]}/hyprlock.conf"
        buf+="${C_MAGENTA}── Preview: ${C_WHITE}${theme_name}${C_MAGENTA} ──${C_RESET}"$'\n'
        if [[ -r "$conf" ]]; then
            local p_line; local -i pcount=0
            while (( pcount < 6 )) && IFS= read -r p_line; do
                buf+="  ${C_GREY}${p_line:0:76}${C_RESET}${CLR_EOL}"$'\n'
                (( pcount++ )) || true 
            done < "$conf"
        else
             buf+="  ${C_RED}(No config found)${C_RESET}${CLR_EOL}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi
    buf+="${CLR_EOS}"
    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -i count=${#THEME_LIST[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

# RESTORED: Page Up/Down logic
navigate_page() {
    local -i dir=$1
    local -i count=${#THEME_LIST[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi
}

# RESTORED: Home/End logic
navigate_end() {
    local -i target=$1 # 0=Start, 1=End
    local -i count=${#THEME_LIST[@]}
    (( count == 0 )) && return 0
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
}

handle_mouse() {
    local input=$1
    local body=${input#'[<'}
    [[ "$body" == "$input" ]] && return 0
    local terminator=${body: -1}
    [[ "$terminator" != "M" && "$terminator" != "m" ]] && return 0
    body=${body%[Mm]}
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    
    local -i button=$field1 x=$field2 y=$field3

    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    [[ "$terminator" != "M" ]] && return 0 

    if (( x > MOUSE_HITBOX_LIMIT )); then return 0; fi

    if (( y >= ITEM_START_ROW && y < ITEM_START_ROW + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - ITEM_START_ROW + SCROLL_OFFSET ))
        if (( clicked_idx >= 0 && clicked_idx < ${#THEME_LIST[@]} )); then
            SELECTED_ROW=$clicked_idx
            if (( button == 0 )); then apply_theme "${THEME_LIST[SELECTED_ROW]}"; fi
        fi
    fi
}

read_escape_seq() {
    local -n _esc_out=$1
    local char
    _esc_out=""
    while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
        _esc_out+="$char"
        case "$_esc_out" in
            '[Z'|O[A-Za-z]|'['*[A-Za-z~]) return 0 ;;
        esac
    done
}

# --- Main ---

main() {
    if (( BASH_VERSINFO[0] < 5 )); then log_err "Bash 5.0+ required"; exit 1; fi
    for _dep in awk sed find sort grep; do
        if ! command -v "$_dep" &>/dev/null; then log_err "Missing dep: $_dep"; exit 1; fi
    done

    init_themes
    detect_active_theme

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null || :
    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    local key escape_seq

    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        if [[ "$key" == $'\x1b' ]]; then
            read_escape_seq escape_seq
            case "$escape_seq" in
                '[A'|'OA')    navigate -1 ;;      # Up Arrow
                '[B'|'OB')    navigate 1 ;;       # Down Arrow
                '[5~')        navigate_page -1 ;; # Page Up
                '[6~')        navigate_page 1 ;;  # Page Down
                '[H'|'[1~')   navigate_end 0 ;;   # Home Key
                '[F'|'[4~')   navigate_end 1 ;;   # End Key
                '['*'<'*[Mm]) handle_mouse "$escape_seq" ;;
            esac
        else
            case "$key" in
                k|K)          navigate -1 ;;
                j|J)          navigate 1 ;;
                g)            navigate_end 0 ;;   # Vim Top
                G)            navigate_end 1 ;;   # Vim Bottom
                $'\r'|"")     apply_theme "${THEME_LIST[SELECTED_ROW]}" ;;
                p|P)          PREVIEW_ENABLED=$(( 1 - PREVIEW_ENABLED )) ;;
                q|Q|$'\x03')  break ;;
            esac
        fi
    done
}

main "$@"
