Bettercap Automate Script

A Bash automation script for WiFi security testing on your own networks.
Combines Bettercap, Aircrack-ng, and mitmproxy into a single interactive workflow.


FEATURES

- Auto-detects wireless adapter
- Auto-installs bettercap, aircrack-ng, mitmproxy if missing
- MITM Attack: ARP spoof + sniff + credential capture
- Handshake Capture: scans WiFi, captures EAPOL, verifies completeness
- URL Redirect: ARP spoof + mitmdump + iptables + auto HTTP server
- File + Message: fake page with custom message + downloadable file
- Click tracking: logs victim IP + timestamp when file is downloaded
- Auto gateway detection (ip route, /proc/net/route, arp fallback)
- Multi-IP detection (192.168.x.x with user selection)
- Credentials saved to credentials.txt
- Handshake saved by ESSID name (e.g., ZAIN_4G.pcap)
- Automatic cleanup on exit (iptables, IP forwarding, background processes)
- Generated hooks are NOT tracked by Git (see .gitignore)


REQUIREMENTS

- Kali Linux (or any Debian-based distro)
- Root privileges
- Wireless adapter supporting monitor mode + packet injection
- bettercap, aircrack-ng, mitmdump (auto-installed if missing)
- Optional: tshark, arping
- Python 3 (for HTTP server and mitmproxy addons)


INSTALLATION

git clone https://github.com/mrunknownerror/bettercap-automate-script.git
cd bettercap-automate-script
chmod +x bettercap-automate-script.sh


USAGE

sudo ./bettercap-automate-script.sh

Follow the interactive menu:

1. MITM Attack       - ARP spoof + sniff + credential capture
2. Handshake Capture - scan WiFi, capture + verify handshake
3. URL Redirect      - ARP spoof + mitmdump + iptables
4. File + Message    - fake page with message + downloadable file
5. Exit


MODE 1 - MITM ATTACK

1. Adapter auto-detected
2. Gateway auto-detected (with manual fallback)
3. Network probe (25s) lists all hosts
4. Select target IP
5. ARP spoof + credential capture starts
6. Credentials saved to credentials.txt
7. Press Ctrl+C to stop

Note: HTTPS credential capture requires sslstrip, which may fail
on HSTS-enabled sites. HTTP login forms work reliably.


MODE 2 - HANDSHAKE CAPTURE

1. WiFi scan (20s) lists ESSID + channel
2. Select target network
3. Attempt 1: PMKID via wifi.assoc (clientless)
4. Attempt 2: wifi.deauth fallback (requires connected client)
5. Verify with aircrack-ng and tshark
6. File saved as handshakes/<ESSID>.pcap


MODE 3 - URL REDIRECT

1. Gateway auto-detected
2. Your IP auto-detected (multiple 192.168.x.x prompts selection)
3. Network probe (25s) lists all hosts
4. Select target IP
5. Enter redirect file path (e.g., fake.html or /home/user/fake.html)
6. Script auto-generates redirect_addon.py
7. HTTP server auto-starts on port 80 (if free)
8. iptables redirect (80/443 -> 8080)
9. mitmdump starts
10. Bettercap ARP spoof starts
11. Victim's HTTP requests redirect to your file

Note: File extensions (.exe, .zip, .pdf, .apk) are NOT redirected,
so downloads still work. HTTPS sites are not redirected unless
mitmproxy CA certificate is installed on the victim.


MODE 4 - FILE + MESSAGE

1. Gateway auto-detected
2. Your IP auto-detected
3. Network probe (25s) lists all hosts
4. Select target IP
5. Enter custom message (e.g., "System update required")
6. Enter file path (e.g., payload.exe or /home/user/payload.exe)
7. Script auto-generates file_message_addon.py
8. iptables redirect (80/443 -> 8080)
9. mitmdump starts
10. Bettercap ARP spoof starts
11. Victim's HTTP requests show fake page with message + download link
12. When victim clicks download:
    - File is downloaded
    - Click logged to clicks.txt (IP + timestamp)
    - Terminal shows [+] Victim <IP> downloaded <FILE>
13. Press Enter to stop
14. Click report is displayed


GENERATED FILES (NOT TRACKED BY GIT)

The script generates these files automatically. They are listed in .gitignore
and will NOT be pushed to GitHub:

- credential_hook.js    - Bettercap HTTP proxy hook
- redirect_addon.py     - mitmproxy redirect addon (Mode 3)
- file_message_addon.py - mitmproxy file/message addon (Mode 4)
- credentials.txt       - captured credentials
- clicks.txt            - download click log
- handshakes/           - captured handshake files

Important: Do NOT manually create these files. The script generates them
with the correct paths and values on each run.


AUTO CLEANUP

The script automatically cleans up on exit (Ctrl+C or normal):

- Kills mitmdump, bettercap, HTTP server
- Removes iptables nat rules
- Disables IP forwarding
- Uses a CLEANUP_DONE flag to prevent duplicate cleanup


TROUBLESHOOTING

Error: Could not find mac for gateway
Fix: Script force-resolves via ping + arping; check AP isolation

Error: arp.spoof could not find spoof targets
Fix: Target must be online; script warms up with ping + arping

Error: no client detected on this AP
Fix: Connect a device to the target AP for deauth to work

Problem: Only your own IP in host list
Fix: Disable AP Isolation / Client Isolation on router

Problem: Handshake is incomplete
Fix: Re-run with a client connected; script verifies with aircrack-ng

Problem: No credentials captured
Fix: Login over HTTPS + HSTS = sslstrip fail
     Check pcap: /tmp/mitm_capture.pcap

Problem: Port 80 already in use
Fix: Script detects and uses existing server, or run:
     sudo ss -tulpen | grep :80

Problem: 502 Bad Gateway on redirect
Fix: HTTP server not running or file not found

Problem: Multiple 192.168.x.x IPs
Fix: Script prompts to select which IP to use

Problem: File not found (Mode 4)
Fix: Place the file in the script folder or provide full path


LEGAL DISCLAIMER

This tool is intended only for testing your own networks and devices.
Using it against networks you do not own or have explicit permission to test
is illegal in most jurisdictions. The author assumes no liability for misuse.


LICENSE

MIT License - see LICENSE file
