#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="deb-procman"
CONFIG_DIR="/etc/${SERVICE_NAME}"
FAVORITES_FILE="${CONFIG_DIR}/favorites.conf"

log()  { echo "[+] $1"; }
info() { echo "[*] $1"; }
err()  { echo "[-] $1" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: su -; bash install.sh"
    exit 1
  }
}

load_favorites() {
  FAVORITES=()
  if [[ -f "$FAVORITES_FILE" ]]; then
    while IFS='|' read -r name type; do
      [[ -n "$name" ]] && FAVORITES+=("${name}|${type}")
    done < "$FAVORITES_FILE"
  fi
}

save_favorites() {
  mkdir -p "$CONFIG_DIR"
  > "$FAVORITES_FILE"
  for entry in "${FAVORITES[@]}"; do
    IFS='|' read -r name type <<< "$entry"
    echo "${name}|${type}" >> "$FAVORITES_FILE"
  done
  log "Favorites saved"
}

is_favorite() {
  local name="$1" type="$2"
  for entry in "${FAVORITES[@]}"; do
    IFS='|' read -r fname ftype <<< "$entry"
    [[ "$fname" == "$name" && "$ftype" == "$type" ]] && return 0
  done
  return 1
}

toggle_favorite() {
  local name="$1" type="$2"
  if is_favorite "$name" "$type"; then
    local new_favs=()
    for entry in "${FAVORITES[@]}"; do
      IFS='|' read -r fname ftype <<< "$entry"
      [[ "$fname" != "$name" || "$ftype" != "$type" ]] && new_favs+=("$entry")
    done
    FAVORITES=("${new_favs[@]}")
  else
    FAVORITES+=("${name}|${type}")
  fi
  save_favorites
}

service_action() {
  local name="$1" action="$2"
  case "$action" in
    start)   systemctl start "$name" 2>/dev/null ;;
    stop)    systemctl stop "$name" 2>/dev/null ;;
    restart) systemctl restart "$name" 2>/dev/null ;;
    enable)  systemctl enable --now "$name" 2>/dev/null ;;
    disable) systemctl disable --now "$name" 2>/dev/null ;;
    status)  systemctl status "$name" 2>/dev/null ;;
  esac
  return $?
}

show_service_menu() {
  local name="$1"
  local status_text active_state enabled_state

  active_state=$(systemctl is-active "$name" 2>/dev/null || echo "unknown")
  enabled_state=$(systemctl is-enabled "$name" 2>/dev/null || echo "unknown")
  status_text="Service: $name\nActive: $active_state\nEnabled: $enabled_state"

  while true; do
    local fav_star="☆"
    is_favorite "$name" "service" && fav_star="★"

    local choice
    choice=$(whiptail --menu --title "Service: $name" \
      "$status_text" 17 60 8 \
      "START"    "Start the service" \
      "STOP"     "Stop the service" \
      "RESTART"  "Restart the service" \
      "ENABLE"   "Enable at boot (bootstart)" \
      "DISABLE"  "Disable at boot" \
      "STATUS"   "View full status" \
      "FAV"      "${fav_star} Toggle favorite" \
      "BACK"     "Return" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      START)
        if service_action "$name" start; then
          whiptail --msgbox "Started: $name" 6 30
        else
          whiptail --msgbox "Failed to start: $name" 6 35
        fi
        active_state=$(systemctl is-active "$name" 2>/dev/null || echo "unknown")
        enabled_state=$(systemctl is-enabled "$name" 2>/dev/null || echo "unknown")
        status_text="Service: $name\nActive: $active_state\nEnabled: $enabled_state"
        ;;
      STOP)
        if service_action "$name" stop; then
          whiptail --msgbox "Stopped: $name" 6 30
        else
          whiptail --msgbox "Failed to stop: $name" 6 35
        fi
        active_state=$(systemctl is-active "$name" 2>/dev/null || echo "unknown")
        status_text="Service: $name\nActive: $active_state\nEnabled: $enabled_state"
        ;;
      RESTART)
        whiptail --msgbox "Restarting: $name..." 6 30
        service_action "$name" restart
        active_state=$(systemctl is-active "$name" 2>/dev/null || echo "unknown")
        status_text="Service: $name\nActive: $active_state\nEnabled: $enabled_state"
        whiptail --msgbox "Restart done. Status: $active_state" 6 35
        ;;
      ENABLE)
        if service_action "$name" enable; then
          whiptail --msgbox "Enabled at boot: $name" 6 35
        else
          whiptail --msgbox "Failed to enable: $name" 6 35
        fi
        enabled_state=$(systemctl is-enabled "$name" 2>/dev/null || echo "unknown")
        status_text="Service: $name\nActive: $active_state\nEnabled: $enabled_state"
        ;;
      DISABLE)
        if service_action "$name" disable; then
          whiptail --msgbox "Disabled at boot: $name" 6 35
        else
          whiptail --msgbox "Failed to disable: $name" 6 35
        fi
        enabled_state=$(systemctl is-enabled "$name" 2>/dev/null || echo "unknown")
        status_text="Service: $name\nActive: $active_state\nEnabled: $enabled_state"
        ;;
      STATUS)
        local full_status
        full_status=$(systemctl status "$name" 2>&1 | head -30)
        whiptail --scrolltext --msgbox "$full_status" 20 75 2>/dev/null || \
          echo "$full_status" | less
        ;;
      FAV)
        toggle_favorite "$name" "service"
        fav_star="☆"
        is_favorite "$name" "service" && fav_star="★"
        whiptail --msgbox "Favorite ${fav_star} toggled for: $name" 6 40
        ;;
      BACK) return ;;
    esac
  done
}

show_service_list() {
  local filter="${1:-}"

  while true; do
    local menu_items=()
    local services=()
    local svc

    if [[ -n "$filter" ]]; then
      while IFS=$'\t' read -r unit active enabled desc; do
        local name="${unit%.service*}"
        [[ -z "$name" ]] && continue
        name="${name//\\//}"
        local fav=" "
        is_favorite "$name" "service" && fav="*"
        local label="${fav} ${name}"
        local status_text="${active}/${enabled}"
        [[ "${#label}" -gt 28 ]] && label="${label:0:25}..."
        services+=("$name|$active|$enabled")
        menu_items+=("$label" "$status_text")
      done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | \
        awk '{print $1"\t"$3"\t"$4"\t"$2}' | grep -i "$filter" | head -100)
    else
      while IFS=$'\t' read -r unit active enabled desc; do
        local name="${unit%.service*}"
        [[ -z "$name" ]] && continue
        name="${name//\\//}"
        local fav=" "
        is_favorite "$name" "service" && fav="*"
        local label="${fav} ${name}"
        local status_text="${active}/${enabled}"
        [[ "${#label}" -gt 28 ]] && label="${label:0:25}..."
        services+=("$name|$active|$enabled")
        menu_items+=("$label" "$status_text")
      done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | \
        awk '{print $1"\t"$3"\t"$4"\t"$2}' | head -100)
    fi

    if [[ ${#menu_items[@]} -eq 0 ]]; then
      whiptail --msgbox "No services found${filter:+ matching '$filter'}." 6 45
      return
    fi

    local extra_opts=()
    [[ -z "$filter" ]] && extra_opts=("__FILTER__" "Search/filter services" "" "" "__REFRESH__" "Refresh list")
    [[ -n "$filter" ]] && extra_opts=("__FILTER__" "Change filter (current: $filter)" "" "" "__CLEAR__" "Clear filter")

    local choice
    choice=$(whiptail --menu --title "Systemd Services${filter:+ (filter: $filter)}" \
      "Select a service to manage:" 20 72 12 \
      "${extra_opts[@]}" \
      "${menu_items[@]}" \
      "__BACK__" "Return to main menu" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      __BACK__) return ;;
      __REFRESH__) continue ;;
      __CLEAR__) filter=""; continue ;;
      __FILTER__)
        filter=$(whiptail --inputbox "Search services:" 8 50 "$filter" 3>&1 1>&2 2>&3) || filter=""
        continue
        ;;
      *)
        local idx=$(( (${#extra_opts[@]}/4) ))
        for ((i=0; i<${#menu_items[@]}; i+=2)); do
          if [[ "${menu_items[$i]}" == "$choice" ]]; then
            local svc_name="${services[$((i/2))]%%|*}"
            show_service_menu "$svc_name"
            break
          fi
        done
        ;;
    esac
  done
}

show_process_list() {
  local filter="${1:-}"

  while true; do
    local menu_items=()
    local procs=()
    local pname pid pcpu pmem

    while IFS='|' read -r pid cpu mem cmd; do
      pname="${cmd##*/}"
      [[ -z "$pname" ]] && pname="$cmd"
      [[ "${#pname}" -gt 25 ]] && pname="${pname:0:22}..."

      if [[ -n "$filter" ]] && ! echo "$pname $cmd" | grep -qi "$filter"; then
        continue
      fi

      local fav=" "
      is_favorite "$pname" "process" && fav="*"
      local label="${fav} ${pname}"
      local info="PID:${pid}  CPU:${cpu}%  MEM:${mem}%"
      procs+=("${pname}|${pid}|${cmd}")
      menu_items+=("$label" "$info")
    done < <(ps -eo pid,pcpu,pmem,comm --no-headers --sort=-pcpu 2>/dev/null | \
      awk '{print $1"|"$2"|"$3"|"$4}' | head -80)

    if [[ ${#menu_items[@]} -eq 0 ]]; then
      whiptail --msgbox "No processes found${filter:+ matching '$filter'}." 6 45
      return
    fi

    local extra_opts=()
    [[ -z "$filter" ]] && extra_opts=("__FILTER__" "Search/filter processes")
    [[ -n "$filter" ]] && extra_opts=("__FILTER__" "Change filter (current: $filter)" "" "" "__CLEAR__" "Clear filter")

    local choice
    choice=$(whiptail --menu --title "Running Processes${filter:+ (filter: $filter)}" \
      "Select a process:" 20 72 12 \
      "${extra_opts[@]}" \
      "${menu_items[@]}" \
      "__BACK__" "Return to main menu" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      __BACK__) return ;;
      __CLEAR__) filter=""; continue ;;
      __FILTER__)
        filter=$(whiptail --inputbox "Search processes:" 8 50 "$filter" 3>&1 1>&2 2>&3) || filter=""
        continue
        ;;
      *)
        for ((i=0; i<${#menu_items[@]}; i+=2)); do
          if [[ "${menu_items[$i]}" == "$choice" ]]; then
            IFS='|' read -r pname pid cmd <<< "${procs[$((i/2))]}"
            show_process_menu "$pname" "$pid" "$cmd"
            break
          fi
        done
        ;;
    esac
  done
}

show_process_menu() {
  local pname="$1" pid="$2" cmd="$3"
  local running=true
  kill -0 "$pid" 2>/dev/null || running=false

  while true; do
    local fav_star="☆"
    is_favorite "$pname" "process" && fav_star="★"
    local status_text="Process: $pname\nPID: $pid\nRunning: $([ "$running" == true ] && echo 'yes' || echo 'no')"

    local choice
    choice=$(whiptail --menu --title "Process: $pname (PID $pid)" \
      "$status_text" 14 60 5 \
      "STOP"   "Kill the process (SIGTERM)" \
      "KILL"   "Force kill (SIGKILL)" \
      "RESTART" "Restart process (if service)" \
      "FAV"    "${fav_star} Toggle favorite" \
      "BACK"   "Return" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      STOP)
        if kill "$pid" 2>/dev/null; then
          whiptail --msgbox "SIGTERM sent to $pname (PID $pid)" 6 40
          running=false
        else
          whiptail --msgbox "Failed to kill $pname (PID $pid)" 6 40
        fi
        ;;
      KILL)
        if kill -9 "$pid" 2>/dev/null; then
          whiptail --msgbox "SIGKILL sent to $pname (PID $pid)" 6 40
          running=false
        else
          whiptail --msgbox "Failed to kill $pname (PID $pid)" 6 40
        fi
        ;;
      RESTART)
        local svc
        svc=$(systemctl list-units --type=service --no-legend 2>/dev/null | \
          awk '{print $1}' | grep -i "$pname" | head -1)
        if [[ -n "$svc" ]]; then
          svc="${svc%.service*}"
          service_action "$svc" restart
          whiptail --msgbox "Service '$svc' restarted." 6 35
        else
          whiptail --msgbox "No matching systemd service found.\nCannot restart arbitrary processes." 7 50
        fi
        ;;
      FAV)
        toggle_favorite "$pname" "process"
        fav_star="☆"
        is_favorite "$pname" "process" && fav_star="★"
        whiptail --msgbox "Favorite ${fav_star} toggled for: $pname" 6 40
        ;;
      BACK) return ;;
    esac
  done
}

show_favorites() {
  if [[ ${#FAVORITES[@]} -eq 0 ]]; then
    whiptail --msgbox "No favorites yet.\n\nBrowse processes or services and press FAV to add them." 8 50
    return
  fi

  while true; do
    local menu_items=()
    local fav_idx=()

    for i in "${!FAVORITES[@]}"; do
      IFS='|' read -r name ftype <<< "${FAVORITES[$i]}"
      local label=""
      local info=""
      if [[ "$ftype" == "service" ]]; then
        local active_state
        active_state=$(systemctl is-active "$name" 2>/dev/null || echo "?")
        label="[SVC] $name"
        info="$active_state"
      else
        local pid_info
        pid_info=$(pgrep -x "$name" 2>/dev/null | head -1)
        [[ -z "$pid_info" ]] && pid_info="not running"
        label="[PRC] $name"
        info="PID $pid_info"
      fi
      [[ "${#label}" -gt 30 ]] && label="${label:0:27}..."
      menu_items+=("$label" "$info")
      fav_idx+=("$i")
    done

    menu_items+=("__REMOVE__" "Remove a favorite" "__BACK__" "Return to main menu")

    local choice
    choice=$(whiptail --menu --title "Favorites (${#FAVORITES[@]})" \
      "Select to manage:" 20 65 10 \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      __BACK__) return ;;
      __REMOVE__)
        local remove_items=()
        local rem_idx=()
        for i in "${!FAVORITES[@]}"; do
          IFS='|' read -r name ftype <<< "${FAVORITES[$i]}"
          local tag="[PRC]"
          [[ "$ftype" == "service" ]] && tag="[SVC]"
          remove_items+=("$i" "${tag} $name")
          rem_idx+=("$i")
        done
        local rem_choice
        rem_choice=$(whiptail --menu --title "Remove Favorite" \
          "Select to remove:" 15 55 8 \
          "${remove_items[@]}" \
          3>&1 1>&2 2>&3) || continue
        local new_favs=()
        for i in "${!FAVORITES[@]}"; do
          [[ "$i" != "$rem_choice" ]] && new_favs+=("${FAVORITES[$i]}")
        done
        FAVORITES=("${new_favs[@]}")
        save_favorites
        continue
        ;;
      *)
        for ((i=0; i<${#menu_items[@]}; i+=2)); do
          if [[ "${menu_items[$i]}" == "$choice" ]]; then
            local idx="${fav_idx[$((i/2))]}"
            IFS='|' read -r name ftype <<< "${FAVORITES[$idx]}"
            if [[ "$ftype" == "service" ]]; then
              show_service_menu "$name"
            else
              local pid
              pid=$(pgrep -x "$name" 2>/dev/null | head -1)
              local cmd="$name"
              if [[ -n "$pid" ]]; then
                cmd=$(ps -p "$pid" -o comm --no-headers 2>/dev/null || echo "$name")
              fi
              show_process_menu "$name" "${pid:-0}" "$cmd"
            fi
            break
          fi
        done
        ;;
    esac
  done
}

show_main_menu() {
  local choice
  choice=$(whiptail --menu --title "Deb ProcMan — Process Manager" \
    "Manage processes and systemd services.\nFavorites: ${#FAVORITES[@]}" \
    14 60 5 \
    "1" "Running processes" \
    "2" "Systemd services" \
    "3" "Favorites (${#FAVORITES[@]})" \
    "4" "Exit" \
    3>&1 1>&2 2>&3) || return 1

  case "$choice" in
    1) show_process_list ;;
    2) show_service_list ;;
    3) show_favorites ;;
    4) return 1 ;;
  esac
  return 0
}

check_deps() {
  if ! command -v whiptail &>/dev/null; then
    apt-get install -y whiptail 2>/dev/null || {
      err "whiptail is required. Install: apt-get install whiptail"
      exit 1
    }
  fi
}

main() {
  require_root
  check_deps
  load_favorites

  while true; do
    show_main_menu || break
  done

  log "Goodbye."
}

main
