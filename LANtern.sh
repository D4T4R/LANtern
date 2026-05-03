#!/usr/bin/env bash
# =============================================================================
#  LANtern.sh — Home Network Scanner & Device Identifier
#  Author: Aniket Datar
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[1;34m'; CYN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${BLU}[*]${NC} $*"; }
success() { echo -e "${GRN}[✔]${NC} $*"; }
warn()    { echo -e "${YLW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
  fi
}

# ── Detect distro & package manager ──────────────────────────────────────────
detect_distro() {
  if   command -v apt-get &>/dev/null; then PM="apt-get"; PM_INSTALL="apt-get install -y"
  elif command -v dnf     &>/dev/null; then PM="dnf";     PM_INSTALL="dnf install -y"
  elif command -v yum     &>/dev/null; then PM="yum";     PM_INSTALL="yum install -y"
  elif command -v pacman  &>/dev/null; then PM="pacman";  PM_INSTALL="pacman -Sy --noconfirm"
  elif command -v zypper  &>/dev/null; then PM="zypper";  PM_INSTALL="zypper install -y"
  else PM="unknown"; PM_INSTALL=""; fi

  DISTRO="Unknown"
  [[ -f /etc/os-release ]] && DISTRO=$(. /etc/os-release; echo "${PRETTY_NAME:-$NAME}")
  info "Distro : ${BOLD}$DISTRO${NC}"
  info "Pkg Mgr: ${BOLD}$PM${NC}"
}

# ── Ensure nmap, or install, or fallback ──────────────────────────────────────
SCAN_MODE="nmap"   # nmap | arp | ping

ensure_nmap() {
  if command -v nmap &>/dev/null; then
    success "nmap found: $(nmap --version | head -1)"
    SCAN_MODE="nmap"
    return
  fi

  warn "nmap not found. Attempting install..."
  detect_distro

  if [[ -n "$PM_INSTALL" ]]; then
    if $PM_INSTALL nmap &>/dev/null; then
      if command -v nmap &>/dev/null; then
        success "nmap installed successfully."
        SCAN_MODE="nmap"
        return
      fi
    fi
  fi

  warn "nmap install failed. Checking fallbacks..."

  if command -v arp-scan &>/dev/null; then
    warn "Fallback: using arp-scan (limited data)"
    SCAN_MODE="arp-scan"
  elif command -v ip &>/dev/null || command -v arp &>/dev/null; then
    warn "Fallback: using arp table + ping sweep (limited data)"
    SCAN_MODE="ping"
  else
    error "No suitable scanner found. Install nmap manually."
    exit 1
  fi
}

# ── Detect local subnet ───────────────────────────────────────────────────────
detect_subnet() {
  # Try ip route first
  SUBNET=$(ip route 2>/dev/null \
    | grep -v default \
    | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
    | awk '{print $1}' \
    | grep -v '169\.254' \
    | head -1)

  # Fallback: derive from primary interface IP
  if [[ -z "$SUBNET" ]]; then
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    PREFIX=$(echo "$LOCAL_IP" | cut -d. -f1-3)
    SUBNET="${PREFIX}.0/24"
  fi

  success "Detected subnet: ${BOLD}$SUBNET${NC}"
}

# ── MAC vendor lookup (macvendors.com API, rate-limited) ──────────────────────
declare -A VENDOR_CACHE

lookup_vendor() {
  local mac="$1"
  local prefix
  prefix=$(echo "$mac" | tr '[:lower:]' '[:upper:]' | cut -c1-8)

  # Return cached result
  if [[ -n "${VENDOR_CACHE[$prefix]+x}" ]]; then
    echo "${VENDOR_CACHE[$prefix]}"
    return
  fi

  # Skip randomized/locally-administered MACs
  local second_nibble
  second_nibble=$(echo "$prefix" | cut -c2 | tr '[:upper:]' '[:lower:]')
  case "$second_nibble" in
    2|6|a|e)
      VENDOR_CACHE[$prefix]="Randomized MAC"
      echo "Randomized MAC"
      return ;;
  esac

  local vendor
  vendor=$(curl -sf --max-time 4 "https://api.macvendors.com/${mac}" 2>/dev/null || echo "")
  [[ -z "$vendor" ]] && vendor="Unknown"

  VENDOR_CACHE[$prefix]="$vendor"
  echo "$vendor"
  sleep 0.8   # respect API rate limit
}

# ── Scan with nmap ────────────────────────────────────────────────────────────
scan_nmap() {
  info "Scanning with nmap (ping sweep)..."
  RAW_SCAN=$(nmap -sn "$SUBNET" 2>/dev/null)
  parse_nmap_output "$RAW_SCAN"
}

parse_nmap_output() {
  local raw="$1"
  local ip="" hostname="" mac="" vendor_nmap=""

  while IFS= read -r line; do
    if echo "$line" | grep -qE "^Nmap scan report"; then
      # Flush previous entry
      [[ -n "$ip" ]] && add_device "$ip" "$hostname" "$mac" "$vendor_nmap"
      ip=""; hostname=""; mac=""; vendor_nmap=""

      if echo "$line" | grep -q "("; then
        hostname=$(echo "$line" | awk '{print $5}')
        ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
      else
        ip=$(echo "$line" | awk '{print $NF}')
        hostname=""
      fi
    elif echo "$line" | grep -q "MAC Address:"; then
      mac=$(echo "$line" | awk '{print $3}')
      vendor_nmap=$(echo "$line" | sed 's/.*MAC Address: [^ ]* //' | tr -d '()')
    fi
  done <<< "$raw"

  # Flush last entry
  [[ -n "$ip" ]] && add_device "$ip" "$hostname" "$mac" "$vendor_nmap"
}

# ── Scan with arp-scan (fallback 1) ──────────────────────────────────────────
scan_arpscan() {
  info "Scanning with arp-scan..."
  local iface
  iface=$(ip route | grep default | awk '{print $5}' | head -1)
  RAW=$(arp-scan --interface="$iface" --localnet 2>/dev/null | grep -E '^[0-9]')
  while IFS=$'\t' read -r ip mac vendor_raw; do
    add_device "$ip" "" "$mac" "$vendor_raw"
  done <<< "$RAW"
}

# ── Scan with ping + arp table (fallback 2) ───────────────────────────────────
scan_ping() {
  info "Running ping sweep (this may take ~30s)..."
  local prefix
  prefix=$(echo "$SUBNET" | cut -d'/' -f1 | cut -d. -f1-3)

  # Parallel ping
  for i in $(seq 1 254); do
    ping -c1 -W1 "${prefix}.${i}" &>/dev/null &
  done
  wait
  success "Ping sweep done. Reading ARP table..."

  while IFS= read -r line; do
    local ip mac
    ip=$(echo "$line"  | awk '{print $1}')
    mac=$(echo "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || echo "")
    [[ -n "$ip" && -n "$mac" ]] && add_device "$ip" "" "$mac" ""
  done < <(arp -n 2>/dev/null | grep -v incomplete | tail -n +2)
}

# ── Device store ──────────────────────────────────────────────────────────────
DEVICE_IPS=()
DEVICE_HOSTNAMES=()
DEVICE_MACS=()
DEVICE_VENDORS=()
DEVICE_TYPES=()

add_device() {
  local ip="$1" hostname="$2" mac="$3" vendor_hint="$4"
  DEVICE_IPS+=("$ip")
  DEVICE_HOSTNAMES+=("$hostname")
  DEVICE_MACS+=("${mac:-N/A}")

  local vendor="$vendor_hint"
  if [[ -z "$vendor" || "$vendor" == "Unknown" ]] && [[ -n "$mac" && "$mac" != "N/A" ]]; then
    info "  Looking up vendor for $mac ..."
    vendor=$(lookup_vendor "$mac")
  fi
  [[ -z "$vendor" ]] && vendor="Unknown"
  DEVICE_VENDORS+=("$vendor")
  DEVICE_TYPES+=("$(guess_device_type "$ip" "$hostname" "$vendor")")
}

# ── Heuristic device type guess ───────────────────────────────────────────────
guess_device_type() {
  local ip="$1" hostname="$2" vendor="$3"
  local v
  v=$(echo "$vendor $hostname" | tr '[:upper:]' '[:lower:]')

  [[ "$ip" == *.1    ]]                    && echo "Router / Gateway"     && return
  echo "$v" | grep -qi "hikvision\|dahua\|reolink\|axis\|amcrest\|uniview" \
                                           && echo "CCTV Camera"          && return
  echo "$v" | grep -qi "tp-link\|netgear\|repeater\|extender\|asus.*rt\|tenda" \
                                           && echo "WiFi Repeater/AP"     && return
  echo "$v" | grep -qi "espressif\|esp32\|esp8266\|growatt\|solis\|huawei.*solar\|goodwe" \
                                           && echo "Solar Inverter / IoT" && return
  echo "$v" | grep -qi "amazon\|echo\|fire\|kindle"  && echo "Amazon Device (Echo/Fire)" && return
  echo "$v" | grep -qi "tcl\|samsung\|lg\|sony\|hisense\|vizio\|philips.*tv\|bravia" \
                                           && echo "Smart TV"             && return
  echo "$v" | grep -qi "hp\|hewlett\|canon\|epson\|brother\|lexmark\|xerox\|ricoh" \
                                           && echo "Printer"              && return
  echo "$v" | grep -qi "apple\|iphone\|ipad\|macbook" \
                                           && echo "Apple Device"         && return
  echo "$v" | grep -qi "randomized"       && echo "Phone (MAC Randomized)" && return
  echo "$v" | grep -qi "azurewave\|intel wireless\|broadcom\|realtek" \
                                           && echo "Laptop / PC WiFi Module" && return
  echo "$v" | grep -qi "asustek\|asus"    && echo "ASUS Device"          && return
  echo "$v" | grep -qi "microsoft"        && echo "Windows Device"       && return
  echo "$v" | grep -qi "raspberry\|raspberrypi" \
                                           && echo "Raspberry Pi"         && return

  echo "Unknown Device"
}

# ── ASCII Table renderer ───────────────────────────────────────────────────────
print_table() {
  local count=${#DEVICE_IPS[@]}
  [[ $count -eq 0 ]] && warn "No devices found." && return

  # Column widths (dynamic)
  local W_IP=15 W_MAC=17 W_TYPE=30 W_VENDOR=35 W_HOST=20

  for i in "${!DEVICE_IPS[@]}"; do
    [[ ${#DEVICE_IPS[$i]}      -gt $W_IP     ]] && W_IP=${#DEVICE_IPS[$i]}
    [[ ${#DEVICE_MACS[$i]}     -gt $W_MAC    ]] && W_MAC=${#DEVICE_MACS[$i]}
    [[ ${#DEVICE_TYPES[$i]}    -gt $W_TYPE   ]] && W_TYPE=${#DEVICE_TYPES[$i]}
    [[ ${#DEVICE_VENDORS[$i]}  -gt $W_VENDOR ]] && W_VENDOR=${#DEVICE_VENDORS[$i]}
    [[ ${#DEVICE_HOSTNAMES[$i]} -gt $W_HOST   ]] && W_HOST=${#DEVICE_HOSTNAMES[$i]}
  done

  # Pad helper
  pad() { printf "%-${2}s" "$1"; }

  # Separator line
  local SEP
  SEP=$(printf '+-%s-+-%s-+-%s-+-%s-+-%s-+\n' \
    "$(printf '%0.s-' $(seq 1 $W_IP))" \
    "$(printf '%0.s-' $(seq 1 $W_MAC))" \
    "$(printf '%0.s-' $(seq 1 $W_TYPE))" \
    "$(printf '%0.s-' $(seq 1 $W_VENDOR))" \
    "$(printf '%0.s-' $(seq 1 $W_HOST))")

  echo ""
  echo -e "${BOLD}${CYN}  HOME NETWORK DEVICE SCAN RESULTS  —  Subnet: $SUBNET${NC}"
  echo ""
  echo "$SEP"
  printf "| ${BOLD}%-${W_IP}s${NC} | ${BOLD}%-${W_MAC}s${NC} | ${BOLD}%-${W_TYPE}s${NC} | ${BOLD}%-${W_VENDOR}s${NC} | ${BOLD}%-${W_HOST}s${NC} |\n" \
    "IP Address" "MAC Address" "Device Type" "Vendor" "Hostname"
  echo "$SEP"

  for i in "${!DEVICE_IPS[@]}"; do
    local color="$NC"
    case "${DEVICE_TYPES[$i]}" in
      "CCTV Camera")               color="$RED"  ;;
      "Router / Gateway")          color="$YLW"  ;;
      "WiFi Repeater/AP")          color="$YLW"  ;;
      "Smart TV")                  color="$CYN"  ;;
      "Solar Inverter / IoT")      color="$GRN"  ;;
      "Amazon Device"*)            color="$BLU"  ;;
      "Phone"*)                    color="$BLU"  ;;
    esac

    printf "| ${color}%-${W_IP}s${NC} | %-${W_MAC}s | %-${W_TYPE}s | %-${W_VENDOR}s | %-${W_HOST}s |\n" \
      "${DEVICE_IPS[$i]}" \
      "${DEVICE_MACS[$i]}" \
      "${DEVICE_TYPES[$i]}" \
      "${DEVICE_VENDORS[$i]}" \
      "${DEVICE_HOSTNAMES[$i]:-—}"
  done

  echo "$SEP"
  echo ""
  success "Total devices found: ${BOLD}$count${NC}"
  echo ""

  # Legend
  echo -e "  ${YLW}■${NC} Gateway/Repeater  ${RED}■${NC} CCTV  ${CYN}■${NC} TV  ${GRN}■${NC} IoT/Solar  ${BLU}■${NC} Amazon/Phone"
  echo ""
}

# ── CSV export (bonus) ─────────────────────────────────────────────────────────
export_csv() {
  local outfile="/tmp/LANtern_$(date +%Y%m%d_%H%M%S).csv"
  echo "IP Address,MAC Address,Device Type,Vendor,Hostname" > "$outfile"
  for i in "${!DEVICE_IPS[@]}"; do
    printf '"%s","%s","%s","%s","%s"\n' \
      "${DEVICE_IPS[$i]}" "${DEVICE_MACS[$i]}" \
      "${DEVICE_TYPES[$i]}" "${DEVICE_VENDORS[$i]}" \
      "${DEVICE_HOSTNAMES[$i]:-}" >> "$outfile"
  done
  success "CSV saved: ${BOLD}$outfile${NC}  (paste into Excel directly)"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}${CYN}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYN}║      LANtern.sh  —  by Aniket        ║${NC}"
  echo -e "${BOLD}${CYN}╚══════════════════════════════════════╝${NC}"
  echo ""

  check_root
  ensure_nmap
  detect_subnet

  case "$SCAN_MODE" in
    nmap)     scan_nmap     ;;
    arp-scan) scan_arpscan  ;;
    ping)     scan_ping     ;;
  esac

  print_table
  export_csv
}

main "$@"
