Bettercap Automate Script

A Bash automation script for WiFi security testing on your own networks.
Combines Bettercap and Aircrack-ng into a single interactive workflow.


FEATURES

- Auto-detects wireless adapter
- Auto-installs bettercap & aircrack-ng if missing
- Handshake Capture: scans networks, lists ESSID + channel, auto deauth
- MITM test: scans LAN, lists IP + MAC, ARP spoof + sniff
- Gateway MAC force-resolve (fixes "Could not find mac for gateway")
- Target MAC warm-up before ARP spoof
- Handshake completeness verification (aircrack-ng + tshark EAPOL count)
- Saves handshake file by ESSID name (e.g., ZAIN_4G.pcap)


REQUIREMENTS

- Kali Linux (or any Debian-based distro)
- Root privileges
- Wireless adapter supporting monitor mode + packet injection
- bettercap, aircrack-ng (auto-installed if missing)
- Optional: tshark, arping


INSTALLATION

git clone https://github.com/mrunknownerror/bettercap-automate-script.git
cd bettercap-automate-script
chmod +x bettercap-automate-script.sh


USAGE

sudo ./bettercap-automate-script.sh

Follow the interactive menu:

1. MITM Attack       - scan LAN, select target IP, ARP spoof + sniff
2. Handshake Capture - scan WiFi, select ESSID, capture + verify handshake
3. Exit


HANDSHAKE CAPTURE FLOW

1. Adapter auto-detected
2. WiFi scan (20s) gives ESSID + channel list
3. Select target network
4. Attempt 1: PMKID via wifi.assoc (clientless)
5. Attempt 2: wifi.deauth fallback (needs a connected client)
6. Verify with aircrack-ng: reports WPA (N handshake)
7. Verify with tshark: reports EAPOL frame count
8. File saved as handshakes/<ESSID>.pcap


MITM STATUS

WARNING: MITM is currently not fully verified.
The ARP spoof + sniff flow may not work reliably in all environments.
It requires the target device to be online and reachable, and the router
must not have AP Isolation / Client Isolation enabled.
Further testing and fixes are pending.


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


LEGAL DISCLAIMER

This tool is intended only for testing your own networks and devices.
Using it against networks you do not own or have explicit permission to test
is illegal in most jurisdictions. The author assumes no liability for misuse.


LICENSE

MIT License - see LICENSE file
