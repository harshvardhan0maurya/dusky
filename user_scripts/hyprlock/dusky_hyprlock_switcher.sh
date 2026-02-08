#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: Hyprlock Theme Manager (htm) - Powered by Dusky TUI Engine v2.8.2
# Description: Enterprise-grade configuration management for Hyprlock themes.
#              Optimized for Arch/Hyprland/UWSM ecosystems.
# Features:    Full Bounding Box (v2.0 style), Robust Engine (v2.8.2).
# -----------------------------------------------------------------------------

set -euo pipefail

# CRITICAL FIX: The "Locale Bomb"
export LC_NUMERIC=C

# --- Bash Version Check ---
if (( BASH_VERSINFO[0] < 5 )); then
    printf 'Error: Bash 5.0+ required (current: %s)\n' "$BASH_VERSION" >&2
    exit 1
fi

# =============================================================================
# ▼ CONFIGURATION & CONSTANTS ▼
# =============================================================================

readonly _CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly CONFIG_ROOT="${_CONFIG_HOME}/hypr"
readonly THEMES_ROOT="${CONFIG_ROOT}/hyprlock_themes"
readonly TARGET_CONFIG="${CONFIG_ROOT}/hyprlock.conf"

readonly APP_TITLE="Hyprlock Theme Manager"
readonly APP_VERSION="v2.0.0"

# TUI Dimensions
declare -ri MAX_DISPLAY_ROWS=14      # Rows of items to show before scrolling
declare -ri BOX_INNER_WIDTH=76       # Width of the UI box
declare -ri ITEM_START_ROW=5         # Row index where items begin rendering
declare -ri ITEM_PADDING=68          # Text padding for labels (adjusted for box width)
declare -ri ADJUST_THRESHOLD=40      # X-pos threshold for mouse click interactions

# --- ANSI Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

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

# Timeout for reading escape sequences
readonly ESC_READ_TIMEOUT=0.02

# --- State Variables ---
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare -i PREVIEW_MODE=0
declare -i TOGGLE_MODE=0
declare ORIGINAL_STTY=""

declare -a TAB_ITEMS_0=()
declare -a THEME_PATHS=()

# =============================================================================
# ▼ CORE FUNCTIONS ▼
# =============================================================================

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n'
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log_info()    { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()     { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

check_deps() {
    local -a deps=(tput realpath find sort awk sed)
    local -a missing=()
    local cmd
    for cmd in "${deps[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        log_err "Missing core dependencies: ${missing[*]}"
        exit 1
    fi
}

init() {
    if (( EUID == 0 )); then
        log_err "Do not run as root."
        exit 1
    fi
    if [[ ! -d "$THEMES_ROOT" ]]; then
        log_err "Themes directory not found: $THEMES_ROOT"
        exit 1
    fi
    check_deps
}

discover_themes() {
    local config_file dir name
    while IFS= read -r -d '' config_file; do
        dir="${config_file%/*}"
        THEME_PATHS+=("$dir")

        name=""
        if [[ -f "${dir}/theme.json" ]] && command -v jq &>/dev/null; then
            name=$(jq -r '.name // empty' "${dir}/theme.json" 2>/dev/null) || true
        fi
        if [[ -z "$name" ]]; then
             name="${dir##*/}"
        fi
        TAB_ITEMS_0+=("$name")
    done < <(find "$THEMES_ROOT" -mindepth 2 -maxdepth 2 \
                  -name "hyprlock.conf" -print0 2>/dev/null | sort -z)

    if (( ${#TAB_ITEMS_0[@]} == 0 )); then
        log_err "No themes found in $THEMES_ROOT"
        exit 1
    fi
}

detect_current_theme() {
    local target="$TARGET_CONFIG"
    local real_target=""
    local real_theme_dir candidate_resolved
    local -i i

    [[ -e "$target" ]] || return 0

    if [[ -L "$target" ]]; then
        real_target=$(realpath -- "$target" 2>/dev/null) || return 0
    elif [[ -f "$target" ]]; then
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            if [[ "$key" == "source" ]]; then
                local path="$value"
                path="${path#"${path%%[![:space:]]*}"}"
                path="${path%"${path##*[![:space:]]}"}"
                if [[ "$path" == "~"* ]]; then
                    path="${HOME}${path:1}"
                fi
                real_target=$(realpath -- "$path" 2>/dev/null)
                break
            fi
        done < "$target"
    fi

    [[ -n "$real_target" ]] || return 0
    real_theme_dir="${real_target%/*}"

    for (( i = 0; i < ${#THEME_PATHS[@]}; i++ )); do
        if [[ "${THEME_PATHS[i]}" == "$real_theme_dir" ]]; then
            SELECTED_ROW=$i
            return 0
        fi
        candidate_resolved=$(realpath -- "${THEME_PATHS[i]}" 2>/dev/null) || continue
        if [[ "$candidate_resolved" == "$real_theme_dir" ]]; then
            SELECTED_ROW=$i
            return 0
        fi
    done
}

apply_theme() {
    local -i idx=$1
    local theme_dir="${THEME_PATHS[idx]}"
    local theme_name="${TAB_ITEMS_0[idx]}"
    local source="${theme_dir}/hyprlock.conf"

    [[ ! -r "$source" ]] && return 1

    local source_entry="${source/#$HOME/\~}"
    if ! printf 'source = %s\n' "$source_entry" > "$TARGET_CONFIG"; then
        return 1
    fi

    if (( TOGGLE_MODE )); then
        printf '%s\n' "$theme_name"
    else
        export APPLIED_THEME_NAME="$theme_name"
    fi
}

# =============================================================================
# ▼ UI ENGINE (DUSKY TUI v2.8.2 + FULL BOX MOD) ▼
# =============================================================================

draw_ui() {
    local buf="" pad_buf="" padded_item="" item display
    local -i i count visible_start visible_end rows_rendered
    local -i visible_len left_pad right_pad
    
    # -------------------------------------------------------------------------
    # Header Box
    # -------------------------------------------------------------------------
    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'
    
    # Separator (Middle Line instead of Bottom closing)
    buf+="${C_MAGENTA}├${H_LINE}┤${C_RESET}"$'\n'

    # -------------------------------------------------------------------------
    # List Rendering (With Side Borders)
    # -------------------------------------------------------------------------
    count=${#TAB_ITEMS_0[@]}
    
    # Scroll Logic
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))

    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi

    local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
    (( max_scroll < 0 )) && max_scroll=0
    (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    # Spacer Line (Top of list inside box)
    if (( SCROLL_OFFSET > 0 )); then
        printf -v pad_buf '%*s' "$(( BOX_INNER_WIDTH - 14 ))" ''
        buf+="${C_MAGENTA}│${C_GREY}    ▲ (more)  ${pad_buf}${C_MAGENTA}│${C_RESET}"$'\n'
    else
        printf -v pad_buf '%*s' "$BOX_INNER_WIDTH" ''
        buf+="${C_MAGENTA}│${pad_buf}│${C_RESET}"$'\n'
    fi

    for (( i = visible_start; i < visible_end; i++ )); do
        item=${TAB_ITEMS_0[i]}
        
        # Truncate if too long to fit in box
        local -i max_item_len=$(( BOX_INNER_WIDTH - 6 )) # 4 spaces left, 2 right
        if (( ${#item} > max_item_len )); then
            item="${item:0:$max_item_len}"
        fi

        printf -v padded_item "%-${ITEM_PADDING}s" "$item"
        
        # Calculate dynamic right padding to align the right border
        # Box Width - (Left Indent 4) - (Item Length) - (Right Border 1)
        # Note: We use ITEM_PADDING for the text field size
        local -i fill_len=$(( BOX_INNER_WIDTH - 4 - ITEM_PADDING ))
        local filler=""
        if (( fill_len > 0 )); then printf -v filler '%*s' "$fill_len" ''; fi

        if (( i == SELECTED_ROW )); then
            # Highlighted Row (Cyan arrow, Inverse text)
            buf+="${C_MAGENTA}│${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET}${filler}${C_MAGENTA}│${C_RESET}"$'\n'
        else
            # Standard Row
            buf+="${C_MAGENTA}│${C_RESET}    ${padded_item}${filler}${C_MAGENTA}│${C_RESET}"$'\n'
        fi
    done

    # Fill remaining rows to maintain box height
    rows_rendered=$(( visible_end - visible_start ))
    printf -v pad_buf '%*s' "$BOX_INNER_WIDTH" ''
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${C_MAGENTA}│${pad_buf}│${C_RESET}"$'\n'
    done

    # -------------------------------------------------------------------------
    # Footer & Bottom Enclosure
    # -------------------------------------------------------------------------
    # Bottom text info inside the box? Or scroll indicator?
    if (( count > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        local -i info_len=${#position_info}
        local -i space_len=$(( BOX_INNER_WIDTH - 14 - info_len - 1 )) # -14 for text, -1 safety
        printf -v pad_buf '%*s' "$space_len" ''
        
        if (( visible_end < count )); then
            buf+="${C_MAGENTA}│${C_GREY}    ▼ (more)  ${pad_buf}${position_info} ${C_MAGENTA}│${C_RESET}"$'\n'
        else
             # Just empty space + info
             printf -v pad_buf '%*s' "$(( BOX_INNER_WIDTH - info_len - 1 ))" ''
             buf+="${C_MAGENTA}│${pad_buf}${C_GREY}${position_info} ${C_MAGENTA}│${C_RESET}"$'\n'
        fi
    else
         # Empty bottom line
         printf -v pad_buf '%*s' "$BOX_INNER_WIDTH" ''
         buf+="${C_MAGENTA}│${pad_buf}│${C_RESET}"$'\n'
    fi

    # CLOSE THE BOX
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    buf+=$'\n'"${C_CYAN} [Enter] Apply  [p] Preview  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    
    # Preview Pane
    if (( PREVIEW_MODE )); then
        local conf="${THEME_PATHS[SELECTED_ROW]}/hyprlock.conf"
        buf+=$'\n'"${C_MAGENTA}── Preview: ${C_WHITE}${TAB_ITEMS_0[SELECTED_ROW]}${C_MAGENTA} ──${C_RESET}"$'\n'
        if [[ -r "$conf" ]]; then
            local line
            local -i pcount=0
            while (( pcount < 8 )) && IFS= read -r line; do
                buf+="  ${C_GREY}${line}${C_RESET}${CLR_EOL}"$'\n'
                (( pcount++ ))
            done < "$conf"
        else
            buf+="  ${C_RED}(Unable to read config)${C_RESET}${CLR_EOL}"$'\n'
        fi
    fi

    buf+="${CLR_EOS}"
    printf '%s' "$buf"
}

# --- Input: Navigation ---
navigate() {
    local -i dir=$1
    local -i count=${#TAB_ITEMS_0[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( SELECTED_ROW + dir ))
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
    return 0
}

navigate_page() {
    local -i dir=$1
    local -i count=${#TAB_ITEMS_0[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
    return 0
}

navigate_end() {
    local -i target=$1
    local -i count=${#TAB_ITEMS_0[@]}
    (( count == 0 )) && return 0
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
    return 0
}

# --- Input: Mouse Handling ---
handle_mouse() {
    local input=$1
    local -i button x y i type
    local regex='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'

    if [[ $input =~ $regex ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}

        if (( button == 64 )); then navigate -1; return 0; fi
        if (( button == 65 )); then navigate 1; return 0; fi

        [[ $type != "M" ]] && return 0

        local -i count=${#TAB_ITEMS_0[@]}
        local -i item_row_start=$(( ITEM_START_ROW + 1 ))

        if (( y >= item_row_start && y < item_row_start + MAX_DISPLAY_ROWS )); then
            local -i clicked_idx=$(( y - item_row_start + SCROLL_OFFSET ))
            if (( clicked_idx >= 0 && clicked_idx < count )); then
                SELECTED_ROW=$clicked_idx
            fi
        fi
    fi
    return 0
}

# --- Interactive Mode ---
run_interactive() {
    local -i total=${#TAB_ITEMS_0[@]}
    local key seq char

    [[ ! -t 0 ]] && { log_err "Interactive mode requires a terminal"; exit 1; }

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null || :

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    
    while true; do
        draw_ui

        IFS= read -rsn1 key || break

        if [[ $key == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do seq+="$char"; done
            case $seq in
                '[A'|'OA')     navigate -1 ;;
                '[B'|'OB')     navigate 1 ;;
                '[5~')         navigate_page -1 ;;
                '[6~')         navigate_page 1 ;;
                '[H'|'[1~')    navigate_end 0 ;;
                '[F'|'[4~')    navigate_end 1 ;;
                '['*'<'*)      handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                g)             navigate_end 0 ;;
                G)             navigate_end 1 ;;
                p|P)           (( PREVIEW_MODE = !PREVIEW_MODE )) ;;
                '')            apply_theme "$SELECTED_ROW"
                               cleanup
                               log_success "Applied theme: ${APPLIED_THEME_NAME:-Unknown}"
                               exit 0 ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done
}

# --- Main Entry Point ---
main() {
    while (( $# )); do
        case "$1" in
            --toggle)  TOGGLE_MODE=1 ;;
            --preview) PREVIEW_MODE=1 ;;
            -h|--help) printf "Usage: %s [--toggle] [--preview]\n" "${0##*/}"; exit 0 ;;
            --) shift; break ;;
            -*) log_err "Unknown option: $1"; exit 1 ;;
            *) break ;;
        esac
        shift
    done

    init
    discover_themes
    detect_current_theme

    if (( TOGGLE_MODE )); then
        local -i total=${#TAB_ITEMS_0[@]}
        (( SELECTED_ROW = (SELECTED_ROW + 1) % total ))
        apply_theme "$SELECTED_ROW"
    else
        run_interactive
    fi
}

main "$@"
