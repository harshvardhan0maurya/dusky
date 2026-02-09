#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky TUI Engine - Hybrid Master v3.3.2 (Space Bug Fix)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Wayland
#
# HYBRID SPECIFICATION:
#   - LOGIC CORE: v2.8.2 (Restored to handle split/nested blocks correctly)
#   - INTERFACE:  v3.2.4 (Modern, stable, high-precision, crash-proof)
#   - SAFETY:     v3.2.4 (Bash 5.0+, Scoped Locales, Signal Traps)
#
# v3.3.2 CHANGELOG:
#   - FIX: Removed trailing space in sed replacement that caused whitespace 
#     accumulation after multiple edits.
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# ▼ USER CONFIGURATION (EDIT THIS SECTION) ▼
# =============================================================================

# POINT THIS TO YOUR REAL CONFIG FILE
readonly CONFIG_FILE="${HOME}/.config/hypr/change_me.conf"
readonly APP_TITLE="Input Config Editor"
readonly APP_VERSION="v3.3.2 (Hybrid)"

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38 # Kept v3.2.4 Fix: Better mouse hitbox
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

declare -ra TABS=("General" "Input" "Display" "Misc")

# Item Registration
# NOTE: For nested blocks (e.g. input { touchpad }), use the LEAF name "touchpad".
register_items() {
    # Tab 0: General
    register 0 "Enable Logs"    'logs_enabled|bool|general|||'          "true"
    register 0 "Timeout (ms)"   'timeout|int|general|0|1000|50'        "100"
    
    # Tab 1: Input
    register 1 "Sensitivity"    'sensitivity|float|input|-1.0|1.0|0.1' "0.0"
    register 1 "Accel Profile"  'accel_profile|cycle|input|flat,adaptive,custom||' "adaptive"
    
    # Tab 2: Display
    register 2 "Border Size"    'border_size|int||0|10|1'              "2"
    register 2 "Blur Enabled"   'blur|bool|decoration|||'              "true"
    
    # Tab 3: Misc
    register 3 "Shadow Color"   'col.shadow|cycle|general|0xee1a1a1a,0xff000000||' "0xee1a1a1a"
}

# Post-Write Hook
post_write_action() {
    # Example: Reload Waybar or Hyprland
    # pgrep -x waybar >/dev/null && killall -SIGUSR2 waybar
    : 
}

# =============================================================================
# ▲ END OF USER CONFIGURATION ▲
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
readonly UNSET_MARKER='«unset»'

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()

for (( _ti = 0; _ti < TAB_COUNT; _ti++ )); do
    declare -ga "TAB_ITEMS_${_ti}=()"
done
unset _ti

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

# --- Regex Helpers (v2.8.2 Logic Compatible) ---

escape_sed_replacement() {
    local _esc_input=$1
    local -n _esc_out_ref=$2
    _esc_input=${_esc_input//\\/\\\\}
    _esc_input=${_esc_input//|/\\|}
    _esc_input=${_esc_input//&/\\&}      # Kept security fix for &
    _esc_input=${_esc_input//$'\n'/\\n}
    _esc_out_ref=$_esc_input
}

escape_sed_pattern() {
    local _esc_input=$1
    local -n _esc_out_ref=$2
    _esc_input=${_esc_input//\\/\\\\}
    _esc_input=${_esc_input//|/\\|}
    _esc_input=${_esc_input//./\\.}
    _esc_input=${_esc_input//\*/\\*}
    _esc_input=${_esc_input//\[/\\[}
    _esc_input=${_esc_input//\]/\\]}
    _esc_input=${_esc_input//^/\\^}
    _esc_input=${_esc_input//\$/\\\$}
    _esc_out_ref=$_esc_input
}

# --- Core Logic Engine (v2.8.2 Logic / v3.2.4 Hygiene) ---

register() {
    local -i tab_idx=$1
    local label=$2 config=$3 default_val=${4:-}

    local key type block min max step
    IFS='|' read -r key type block min max step <<< "$config"

    case "$type" in
        bool|int|float|cycle) ;;
        *) log_err "Invalid type for '${label}': ${type}"; exit 1 ;;
    esac

    if (( tab_idx < 0 || tab_idx >= TAB_COUNT )); then
        log_err "Tab index ${tab_idx} out of bounds (0-$(( TAB_COUNT - 1 )))"; exit 1
    fi

    ITEM_MAP["${tab_idx}::${label}"]=$config
    [[ -n "$default_val" ]] && DEFAULTS["${tab_idx}::${label}"]=$default_val

    local -n _reg_tab_ref="TAB_ITEMS_${tab_idx}"
    _reg_tab_ref+=("$label")
}

# The "Brain" from v2.8.2 - Handles split blocks
# UPDATE v3.3.1: Scoped LC_NUMERIC=C to awk command (Hygiene Fix)
populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part || [[ -n ${key_part:-} ]]; do
        [[ -z ${key_part:-} ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part

        key_name=${key_part%%|*}
        if [[ -z ${CONFIG_CACHE["${key_name}|"]:-} ]]; then
            CONFIG_CACHE["${key_name}|"]=$value_part
        fi
    done < <(LC_NUMERIC=C awk '
        BEGIN { depth = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/#.*/, "", line)

            tmpline = line
            while (match(tmpline, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_str = substr(tmpline, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_str)
                depth++
                block_stack[depth] = block_str
                tmpline = substr(tmpline, RSTART + RLENGTH)
            }

            if (line ~ /=/) {
                eq_pos = index(line, "=")
                if (eq_pos > 0) {
                    key = substr(line, 1, eq_pos - 1)
                    val = substr(line, eq_pos + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }

            n = gsub(/\}/, "}", line)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
    ' "$CONFIG_FILE")
}

# The "Seeker" from v2.8.2 - Correctly finds keys in split/nested blocks
# UPDATE v3.3.1: Scoped LC_NUMERIC=C to awk command (Hygiene Fix)
find_key_line_in_block() {
    local block_name=$1 key_name=$2 file=$3

    LC_NUMERIC=C awk -v target_block="$block_name" -v target_key="$key_name" '
    BEGIN {
        depth = 0
        in_target = 0
        target_depth = 0
        found = 0
    }
    {
        line = $0
        clean = $0
        sub(/#.*/, "", clean)

        tmpline = clean
        while (match(tmpline, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
            block_str = substr(tmpline, RSTART, RLENGTH)
            sub(/[[:space:]]*\{/, "", block_str)
            depth++
            block_stack[depth] = block_str

            if (block_str == target_block && !in_target) {
                in_target = 1
                target_depth = depth
            }
            tmpline = substr(tmpline, RSTART + RLENGTH)
        }

        if (in_target && clean ~ /=/) {
            eq_pos = index(clean, "=")
            if (eq_pos > 0) {
                k = substr(clean, 1, eq_pos - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (k == target_key) {
                    print NR
                    found = 1
                }
            }
        }

        n = gsub(/\}/, "}", clean)
        while (n > 0 && depth > 0) {
            if (in_target && depth == target_depth) {
                in_target = 0
                target_depth = 0
            }
            depth--
            n--
        }
    }
    ' "$file"
}

# The "Writer" from v2.8.2
write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local current_val=${CONFIG_CACHE["$key|$block"]:-}
    
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val safe_sed_key
    escape_sed_replacement "$new_val" safe_val
    escape_sed_pattern "$key" safe_sed_key

    if [[ -n "$block" ]]; then
        local target_output
        target_output=$(find_key_line_in_block "$block" "$key" "$CONFIG_FILE")

        if [[ -z "$target_output" ]]; then
            return 1
        fi
        
        local target_line
        while IFS= read -r target_line; do
            [[ ! "$target_line" =~ ^[0-9]+$ ]] && continue
            (( target_line == 0 )) && continue

            # FIX: Removed the trailing space after ${safe_val}
            sed --follow-symlinks -i \
                "${target_line}s|^\([[:space:]]*${safe_sed_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val}|" \
                "$CONFIG_FILE"
        done <<< "$target_output"
    else
        # FIX: Removed the trailing space after ${safe_val}
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${safe_sed_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val}|" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block"]=$new_val
    if [[ -z "$block" ]]; then
        CONFIG_CACHE["$key|"]=$new_val
    fi
    return 0
}

# Bridging the Cache formats
load_tab_values() {
    local -n _ltv_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${_ltv_items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP["${CURRENT_TAB}::${item}"]}"
        
        val=${CONFIG_CACHE["$key|$block"]:-}
        if [[ -z "$val" && -z "$block" ]]; then
            val=${CONFIG_CACHE["$key|"]:-}
        fi
        
        if [[ -z "$val" ]]; then
            VALUE_CACHE["${CURRENT_TAB}::${item}"]=$UNSET_MARKER
        else
            VALUE_CACHE["${CURRENT_TAB}::${item}"]=$val
        fi
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP["${CURRENT_TAB}::${label}"]}"
    current=${VALUE_CACHE["${CURRENT_TAB}::${label}"]:-}

    if [[ "$current" == "$UNSET_MARKER" || -z "$current" ]]; then
        current=${DEFAULTS["${CURRENT_TAB}::${label}"]:-}
        [[ -z "$current" ]] && current=${min:-0}
    fi

    case "$type" in
        int)
            if [[ ! "$current" =~ ^-?[0-9]+$ ]]; then current=${min:-0}; fi
            local -i int_step=${step:-1} int_val=$current
            int_val=$(( int_val + direction * int_step ))
            if [[ -n "$min" ]] && (( int_val < min )); then int_val=$min; fi
            if [[ -n "$max" ]] && (( int_val > max )); then int_val=$max; fi
            new_val=$int_val
            ;;
        float)
            if [[ ! "$current" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then current=${min:-0.0}; fi
            # Using v3.2.4 improved precision logic (%.6g)
            new_val=$(LC_NUMERIC=C awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" 'BEGIN {
                val = c + (dir * s)
                if (mn != "" && val < mn) val = mn
                if (mx != "" && val > mx) val = mx
                printf "%.6g", val
            }')
            ;;
        bool)
            if [[ "$current" == "true" ]]; then new_val="false"; else new_val="true"; fi
            ;;
        cycle)
            local -a opts
            IFS=',' read -r -a opts <<< "$min"
            local -i count=${#opts[@]} idx=0 i
            (( count == 0 )) && return 0
            for (( i = 0; i < count; i++ )); do
                if [[ "${opts[i]}" == "$current" ]]; then idx=$i; break; fi
            done
            idx=$(( (idx + direction + count) % count ))
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["${CURRENT_TAB}::${label}"]=$new_val
        post_write_action
    fi
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP["${CURRENT_TAB}::${label}"]}"
    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["${CURRENT_TAB}::${label}"]=$new_val
        return 0
    fi
    return 1
}

reset_defaults() {
    local -n _rd_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val
    local -i any_written=0
    for item in "${_rd_items_ref[@]}"; do
        def_val=${DEFAULTS["${CURRENT_TAB}::${item}"]:-}
        if [[ -n "$def_val" ]]; then
            if set_absolute_value "$item" "$def_val"; then
                any_written=1
            fi
        fi
    done
    (( any_written )) && post_write_action
    return 0
}

# --- UI Rendering (v3.2.4 Modern) ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad
    local -i visible_start visible_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        len=${#name}
        zone_start=$current_col
        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi
        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        current_col=$(( current_col + len + 4 ))
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    local -n _draw_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    count=${#_draw_items_ref[@]}

    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
    else
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
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    for (( i = visible_start; i < visible_end; i++ )); do
        item=${_draw_items_ref[i]}
        val=${VALUE_CACHE["${CURRENT_TAB}::${item}"]:-${UNSET_MARKER}}
        case "$val" in
            true)              display="${C_GREEN}ON${C_RESET}" ;;
            false)             display="${C_RED}OFF${C_RESET}" ;;
            "$UNSET_MARKER")   display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            *)                 display="${C_WHITE}${val}${C_RESET}" ;;
        esac
        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:${ITEM_PADDING}}"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    local -i rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    if (( count > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        if (( visible_end < count )); then
            buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        else
            buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    printf '%s' "$buf"
}

# --- Input Handling (v3.2.4 Modern) ---

navigate() {
    local -i dir=$1
    local -n _nav_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_nav_items_ref[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

navigate_page() {
    local -i dir=$1
    local -n _navp_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_navp_items_ref[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi
}

navigate_end() {
    local -i target=$1
    local -n _nave_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_nave_items_ref[@]}
    (( count == 0 )) && return 0
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
}

adjust() {
    local -i dir=$1
    local -n _adj_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    (( ${#_adj_items_ref[@]} == 0 )) && return 0
    modify_value "${_adj_items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}
    CURRENT_TAB=$(( (CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i start end
    local type zone

    # Kept v3.2.4 Input Parsing (Fast String Stripping)
    local body=${input#'[<'}
    [[ "$body" == "$input" ]] && return 0
    local terminator=${body: -1}
    [[ "$terminator" != "M" && "$terminator" != "m" ]] && return 0
    body=${body%[Mm]}
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    [[ ! "$field1" =~ ^[0-9]+$ ]] && return 0
    [[ ! "$field2" =~ ^[0-9]+$ ]] && return 0
    [[ ! "$field3" =~ ^[0-9]+$ ]] && return 0
    button=$field1; x=$field2; y=$field3

    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    [[ "$terminator" != "M" ]] && return 0

    if (( y == TAB_ROW )); then
        for (( i = 0; i < TAB_COUNT; i++ )); do
            zone=${TAB_ZONES[i]}
            start=${zone%%:*}
            end=${zone##*:}
            if (( x >= start && x <= end )); then set_tab "$i"; return 0; fi
        done
    fi

    if (( y >= ITEM_START_ROW && y < ITEM_START_ROW + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - ITEM_START_ROW + SCROLL_OFFSET ))
        local -n _mouse_items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#_mouse_items_ref[@]}
        if (( clicked_idx >= 0 && clicked_idx < count )); then
            SELECTED_ROW=$clicked_idx
            if (( x > ADJUST_THRESHOLD )); then
                if (( button == 0 )); then adjust 1; else adjust -1; fi
            fi
        fi
    fi
    return 0
}

read_escape_seq() {
    local -n _esc_out=$1
    local char
    _esc_out=""
    while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
        _esc_out+="$char"
        case "$_esc_out" in
            '[Z')              return 0 ;;
            O[A-Za-z])         return 0 ;;
            '['*[A-Za-z~])     return 0 ;;
        esac
    done
    return 0
}

main() {
    if (( BASH_VERSINFO[0] < 5 )); then
        log_err "Bash 5.0+ required (found ${BASH_VERSION})"; exit 1
    fi
    if [[ ! -t 0 ]]; then
        log_err "Interactive terminal (TTY) required on stdin"; exit 1
    fi

    # Auto-generate dummy config if missing
    # generate_dummy_config

    if [[ ! -f "$CONFIG_FILE" ]]; then log_err "Config not found: ${CONFIG_FILE}"; exit 1; fi
    if [[ ! -r "$CONFIG_FILE" ]]; then log_err "Config not readable: ${CONFIG_FILE}"; exit 1; fi
    if [[ ! -w "$CONFIG_FILE" ]]; then log_err "Config not writable: ${CONFIG_FILE}"; exit 1; fi

    local _dep
    for _dep in awk sed; do
        if ! command -v "$_dep" &>/dev/null; then
            log_err "Required dependency not found: ${_dep}"; exit 1
        fi
    done

    register_items
    populate_config_cache

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    if ! stty -icanon -echo min 1 time 0 2>/dev/null; then
        log_err "Failed to configure terminal (stty). Cannot run interactively."; exit 1
    fi

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_tab_values

    local key escape_seq

    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        if [[ "$key" == $'\x1b' ]]; then
            read_escape_seq escape_seq
            case "$escape_seq" in
                '[Z')                switch_tab -1 ;;
                '[A'|'OA')           navigate -1 ;;
                '[B'|'OB')           navigate 1 ;;
                '[C'|'OC')           adjust 1 ;;
                '[D'|'OD')           adjust -1 ;;
                '[5~')               navigate_page -1 ;;
                '[6~')               navigate_page 1 ;;
                '[H'|'[1~')          navigate_end 0 ;;
                '[F'|'[4~')          navigate_end 1 ;;
                '['*'<'*[Mm])        handle_mouse "$escape_seq" ;;
            esac
        else
            case "$key" in
                k|K)            navigate -1 ;;
                j|J)            navigate 1 ;;
                l|L)            adjust 1 ;;
                h|H)            adjust -1 ;;
                g)              navigate_end 0 ;;
                G)              navigate_end 1 ;;
                $'\t')          switch_tab 1 ;;
                r|R)            reset_defaults ;;
                q|Q|$'\x03')    break ;;
            esac
        fi
    done
}

main "$@"
