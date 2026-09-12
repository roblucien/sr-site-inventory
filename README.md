# sr-site-inventory

A lightweight, interactive TUI for documenting server installs. Runs on any Ubuntu/Debian server via a single `curl` command — no pre-installation required.

Gathers hardware and network info automatically, prompts for the rest, renders a formatted summary, and optionally uploads the report as a private GitHub Gist.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/roblucien/sr-site-inventory/main/install-report.sh | bash
```

Or download and run directly:

```bash
wget -O install-report.sh https://raw.githubusercontent.com/roblucien/sr-site-inventory/main/install-report.sh
bash install-report.sh
```

---

## What it collects

**Automatically from the server:**
- Make, model, serial number — via `dmidecode`
- IP address and NIC MAC — via `ifconfig eno1`
- Install date and location — from system clock and hostname

**Automatically from the network** *(if tools are present, skipped gracefully if not):*
- Network switch — MAC, IP, hostname, manufacturer — via `dhcp-lease-list`
- Switch serial number and SFP module info — via SSH into the switch (`show inventory`)
- Camera/network devices — MAC, IP, hostname, vendor, model, serial — via a network device detection tool

**Prompted interactively:**
- Onsite technician name
- Support contact name
- Job / ticket number *(optional)*
- Notes *(optional)*

---

## Flow

1. Auto-discovery runs on launch
2. Interactive prompts fill in what can't be detected
3. A formatted report renders in the terminal
4. Choose an action:
   - **Generate & upload** — creates a private GitHub Gist and shows the link
   - **Edit a field** — correct any value and return to the report
   - **Start over** — re-run discovery from scratch
   - **Quit** — exit and keep the local copy

---

## Dependencies

Checked and offered for auto-install on first run (requires `sudo`):

| Package | Purpose |
|---|---|
| `whiptail` | Interactive menus and prompts |
| `dmidecode` | Server hardware info |
| `curl` | Gist upload |
| `python3` | JSON payload encoding |
| `expect` | SSH into network switch |

All available via `apt` on Ubuntu 22.04 / 24.04.

---

## GitHub Gist upload *(optional)*

Reports are uploaded as **secret (unlisted) Gists** — not indexed, accessible only via direct link.

You need a GitHub Personal Access Token with `gist` scope:

1. Go to **github.com → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Generate a token with only the `gist` scope checked
3. Paste it when prompted at upload time — it is never stored on disk

---

## Report output

A local Markdown copy is always saved to `/tmp/sr-report-<LOCATION>-<DATE>.md` regardless of whether the Gist upload succeeds.

---

## Notes

- If optional network tools are not present, the script warns and continues — nothing breaks
- Hostname location parsing expects a site-coded hostname convention; falls back to raw hostname if not matched
- Switch SSH username is prompted at runtime and can be set to whatever the switch requires
- Tested on Ubuntu 22.04 and 24.04 headless servers over SSH
