# 🏮 LANtern

> *Lights up every dark corner of your LAN.*

`LANtern` is a zero-dependency\* shell script that scans your home or office Wi-Fi network, identifies every active device by MAC address, enriches unknown vendors via the macvendors.com API, and renders a clean colour-coded ASCII table — all in one shot.

Built for Linux. Works with repeaters, IoT devices, CCTVs, smart TVs, solar inverters — anything on the same subnet.

---

## ✨ Features

- **Auto subnet detection** — no need to type your IP range manually
- **nmap-first with graceful fallbacks** — installs nmap if missing, falls back to `arp-scan`, then ping sweep + ARP table
- **Distro-aware installer** — detects apt / dnf / pacman / zypper / yum automatically
- **MAC vendor enrichment** — nmap's local DB first, then live lookup via [macvendors.com](https://macvendors.com) API for unknowns
- **Randomized MAC detection** — flags phones with MAC randomization instead of misidentifying them
- **Heuristic device typing** — identifies Hikvision CCTVs, Espressif IoT/solar inverters, Amazon Echo/Fire, smart TVs, printers, repeaters and more
- **Colour-coded ASCII table** — device categories highlighted at a glance
- **CSV export** — auto-saves to `/tmp/net_scan_<timestamp>.csv`, paste directly into Excel

---

## 📸 Sample Output

```
╔══════════════════════════════════════╗
║      LANtern  —  by Aniket           ║
╚══════════════════════════════════════╝

[✔] nmap found: Nmap version 7.94
[✔] Detected subnet: 192.168.1.0/24
[*] Scanning with nmap (ping sweep)...
[*]   Looking up vendor for C8:6C:3D:ED:3C:C8 ...

  HOME NETWORK DEVICE SCAN RESULTS  —  Subnet: 192.168.1.0/24

+-----------------+-------------------+------------------------------+-------------------------------------+----------------------+
| IP Address      | MAC Address       | Device Type                  | Vendor                              | Hostname             |
+-----------------+-------------------+------------------------------+-------------------------------------+----------------------+
| 192.168.1.1     | 20:0C:86:1C:16:20 | Router / Gateway             | Unknown                             | _gateway             |
| 192.168.1.2     | 50:D4:F7:CD:02:B0 | WiFi Repeater/AP             | Tp-link Technologies                | —                    |
| 192.168.1.5     | F6:6A:BB:F9:BF:1B | Phone (MAC Randomized)       | Randomized MAC                      | —                    |
| 192.168.1.8     | A0:6F:AA:F6:85:94 | Smart TV                     | LG Innotek                          | —                    |
| 192.168.1.11    | 68:FE:71:A8:FC:68 | Solar Inverter / IoT         | Espressif Inc.                      | —                    |
| 192.168.1.13    | C0:51:7E:41:9C:DE | CCTV Camera                  | Hangzhou Hikvision Digital Tech     | —                    |
| 192.168.1.19    | C8:7E:A1:0A:09:EB | Smart TV                     | TCL Moka International Limited      | —                    |
| 192.168.1.101   | 32:DE:4B:09:41:6D | Amazon Device (Echo/Fire)    | Amazon Technologies Inc.            | —                    |
| 192.168.1.33    | —                 | Unknown Device               | —                                   | pop-os               |
+-----------------+-------------------+------------------------------+-------------------------------------+----------------------+

[✔] Total devices found: 9
[✔] CSV saved: /tmp/net_scan_20250503_1142.csv
```

---

## 🚀 Quick Start

```bash
# Clone
git clone https://github.com/D4T4R>/LANtern.git
cd LANtern

# Make executable
chmod +x LANtern.sh

# Run (root required for raw socket access)
sudo ./LANtern.sh
```

---

## 🔧 Requirements

| Tool | Required | Notes |
|------|----------|-------|
| `bash` | ✅ | v4.0+ |
| `nmap` | ✅ preferred | Auto-installed if missing |
| `curl` | ✅ | For MAC vendor API lookup |
| `ip` / `arp` | ✅ | Usually pre-installed on all distros |
| `arp-scan` | ⚡ fallback | Used if nmap install fails |
| `ping` | ⚡ fallback | Last resort sweep |

> \* `curl` must be available for vendor enrichment. All other dependencies are either pre-installed or auto-installed by the script.

---

## 🧠 How It Works

```
START
  │
  ├─ Check root
  ├─ Detect nmap → install if missing (apt/dnf/pacman/zypper/yum)
  │     └─ Fallback 1: arp-scan
  │     └─ Fallback 2: ping sweep + arp table
  │
  ├─ Auto-detect subnet via ip route
  │
  ├─ Scan subnet for active hosts + MACs
  │
  ├─ For each device:
  │     ├─ Check nmap's local vendor DB
  │     ├─ If unknown → curl macvendors.com API (rate-limited, cached)
  │     └─ Heuristic match → assign device type
  │
  ├─ Render colour-coded ASCII table
  └─ Export CSV to /tmp/
```

---

## 🎨 Device Type Colour Legend

| Colour | Device Category |
|--------|----------------|
| 🟡 Yellow | Router / Gateway / Repeater |
| 🔴 Red | CCTV Camera |
| 🔵 Blue | Amazon Device / Phone |
| 🟢 Green | IoT / Solar Inverter |
| 🩵 Cyan | Smart TV |
| White | Everything else |

---

## 📁 CSV Export

Every run auto-saves a CSV to `/tmp/`:

```
/tmp/net_scan_20250503_114200.csv
```

Columns: `IP Address, MAC Address, Device Type, Vendor, Hostname`

Open directly in Excel or LibreOffice Calc — no formatting needed.

---

## 🔍 Supported Device Detection

| Vendor / Keyword | Detected As |
|-----------------|-------------|
| Hikvision, Dahua, Reolink, Axis | CCTV Camera |
| Espressif, Growatt, Solis, GoodWe | Solar Inverter / IoT |
| TP-Link, Netgear, Tenda | WiFi Repeater / AP |
| Amazon, Echo, Fire, Kindle | Amazon Device |
| TCL, Samsung, LG, Sony, Hisense | Smart TV |
| HP, Canon, Epson, Brother | Printer |
| Apple, iPhone, iPad | Apple Device |
| AzureWave, Intel Wireless, Realtek | Laptop / PC WiFi Module |
| Randomized MAC (locally administered bit) | Phone (MAC Randomized) |

---

## ⚠️ Notes

- **Must be run as root** (`sudo`) — raw socket access is required for MAC address resolution
- The macvendors.com API has a rate limit; the script adds an 0.8s delay between lookups and caches results within the same run
- Devices connected via your **repeater on the same subnet** are included automatically — no extra config needed
- Randomized MACs (common on Android 10+, iOS 14+) cannot be reliably identified and are flagged as such

---

## 🛠️ Tested On

- Pop!_OS 22.04 / Ubuntu 22.04
- Debian 12
- Fedora 39
- Arch Linux
- Raspberry Pi OS

---

## 📜 License

MIT — do whatever you want, attribution appreciated.

---

## 🤝 Contributing

PRs welcome. Ideas for improvement:
- [ ] `--watch` mode to detect new devices joining in real time
- [ ] Port scan integration for deeper device fingerprinting
- [ ] Persistent device DB across runs (track new/missing devices)
- [ ] Telegram / Slack alert on unknown device joining

---

*Made with 🏮 and too much curiosity about what's on the network.*
