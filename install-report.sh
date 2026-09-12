#!/usr/bin/env bash
# install-report.sh — Sportradar Site Install Inventory
# https://github.com/roblucien/sr-site-inventory

# When piped via curl|bash, stdin is the pipe not a tty — save script and re-exec with /dev/tty
if [[ ! -t 0 ]]; then
    tmp=$(mktemp /tmp/sr-report-XXXXXX.sh)
    cat > "$tmp"
    chmod +x "$tmp"
    exec bash "$tmp" "$@" < /dev/tty
fi

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
B=$(tput bold   2>/dev/null || printf '')
R=$(tput sgr0   2>/dev/null || printf '')
CY=$(tput setaf 6 2>/dev/null || printf '')
GR=$(tput setaf 2 2>/dev/null || printf '')
YL=$(tput setaf 3 2>/dev/null || printf '')
RD=$(tput setaf 1 2>/dev/null || printf '')
COLS=$(tput cols 2>/dev/null || echo 80)

hr()      { printf "${CY}"; printf '%*s' "$COLS" '' | tr ' ' '─'; printf "${R}\n"; }
section() { printf "\n${B}${CY} ◆ %s${R}\n" "$1"; }
field()   { printf "   ${B}%-22s${R}%s\n" "$1:" "$2"; }
info()    { printf "  ${GR}✔${R}  %s\n" "$1"; }
warn()    { printf "  ${YL}⚠${R}  %s\n" "$1"; }
err()     { printf "  ${RD}✖${R}  %s\n" "$1" >&2; }

# ── Data ──────────────────────────────────────────────────────────────────────
SRV_MAKE="N/A"; SRV_MODEL="N/A"; SRV_SERIAL="N/A"; SRV_IP="N/A"; SRV_NIC_MAC="N/A"
INST_DATE=""; LOCATION=""
SW_MAC="N/A"; SW_IP="N/A"; SW_HOST="N/A"; SW_MFR="N/A"; SW_SERIAL="N/A"
SW_SFP_PID="N/A"; SW_SFP_SN="N/A"
CAMERAS=()
TECH_NAME=""; SR_CONTACT=""; JOB_NUM=""; NOTES=""
REPORT_FILE=""; GIST_URL=""

# ── Dependencies ──────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in whiptail dmidecode curl python3 expect; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    printf "${YL}Missing packages: %s${R}\n" "${missing[*]}"
    read -rp "  Install now (requires sudo)? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { err "Aborting."; exit 1; }
    sudo apt-get install -y "${missing[@]}" || { err "Install failed."; exit 1; }
}

# ── Discovery ─────────────────────────────────────────────────────────────────
discover_server() {
    local dmi
    dmi=$(sudo dmidecode -t system 2>/dev/null || true)
    SRV_MAKE=$(grep -m1   'Manufacturer:'  <<< "$dmi" | sed 's/.*Manufacturer:[[:space:]]*//'  | xargs)
    SRV_MODEL=$(grep -m1  'Product Name:'  <<< "$dmi" | sed 's/.*Product Name:[[:space:]]*//'  | xargs)
    SRV_SERIAL=$(grep -m1 'Serial Number:' <<< "$dmi" | sed 's/.*Serial Number:[[:space:]]*//' | xargs)
    [[ -z "$SRV_MAKE"   ]] && SRV_MAKE="N/A"
    [[ -z "$SRV_MODEL"  ]] && SRV_MODEL="N/A"
    [[ -z "$SRV_SERIAL" ]] && SRV_SERIAL="N/A"
    INST_DATE=$(date '+%Y-%m-%d %H:%M')
    LOCATION=$(hostname | grep -oP 'KS-US-[A-Z0-9]+' || hostname)

    local ifc
    ifc=$(ifconfig eno1 2>/dev/null || true)
    SRV_IP=$(grep -oP 'inet \K[0-9.]+' <<< "$ifc" | head -1)
    SRV_NIC_MAC=$(grep -oP 'ether \K[0-9a-f:]+' <<< "$ifc" | head -1)
    [[ -z "$SRV_IP"      ]] && SRV_IP="N/A"
    [[ -z "$SRV_NIC_MAC" ]] && SRV_NIC_MAC="N/A"
}

discover_switch() {
    local raw line
    raw=$(sudo dhcp-lease-list 2>/dev/null || true)
    # Switch is always the LAST entry in the lease list
    line=$(awk '/([0-9]{1,3}\.){3}[0-9]/{last=$0} END{print last}' <<< "$raw")
    if [[ -z "$line" ]]; then
        warn "No DHCP lease found for switch."
        return 0
    fi
    # dhcp-lease-list columns: MAC  IP  hostname  expiry-date  expiry-time  manufacturer...
    SW_MAC=$(awk  '{print $1}' <<< "$line")
    SW_IP=$(awk   '{print $2}' <<< "$line")
    SW_HOST=$(awk '{print $3}' <<< "$line")
    SW_MFR=$(awk  '{$1=$2=$3=$4=$5=""; gsub(/^[[:space:]]+/,""); print}' <<< "$line" | xargs)
    [[ -z "$SW_IP"   ]] && SW_IP="N/A"
    [[ -z "$SW_MAC"  ]] && SW_MAC="N/A"
    [[ -z "$SW_HOST" ]] && SW_HOST="N/A"
    [[ -z "$SW_MFR"  ]] && SW_MFR="N/A"
}

discover_switch_serial() {
    [[ "$SW_IP" == "N/A" ]] && return 0

    local sw_user val
    val=$(wt_input "Switch Login" "SSH username for switch at ${SW_IP}:" "keeadmin") \
        && sw_user="$val" || return 0
    [[ -z "$sw_user" ]] && return 0

    local sw_pass
    sw_pass=$(whiptail --passwordbox \
        "SSH password for ${sw_user}@${SW_IP}:" \
        8 56 --title "Switch Login" 3>&1 1>&2 2>&3) || return 0
    [[ -z "$sw_pass" ]] && return 0

    info "SSHing into switch ${SW_IP} as ${sw_user}..."

    # Pass password via env var to avoid Tcl escaping issues
    local inv
    inv=$(SWITCH_PASS="$sw_pass" expect 2>/dev/null << EXPECTEOF
log_user 0
set timeout 15
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${sw_user}@${SW_IP}
expect {
    -re "yes/no.*\\\\?" { send "yes\r"; exp_continue }
    -nocase "password:"  { send "\$env(SWITCH_PASS)\r" }
    timeout { exit 1 }
    eof     { exit 1 }
}
expect "#"
send "show inventory\r"
expect "#"
puts \$expect_out(buffer)
send "exit\r"
expect eof
EXPECTEOF
) || { warn "Switch SSH failed — serial will be N/A"; return 0; }

    # Parse chassis (NAME: "1") and SFP (NAME: 2nd block) PID/SN
    # Format: PID: C1300-8MGP-2X   VID: V01   SN: DNI29230A4N
    local parsed_inv
    parsed_inv=$(awk '
        /NAME:/ { block++ }
        block == 1 && /PID:/ {
            match($0, /SN:[[:space:]]*([^[:space:]]+)/, s)
            print "chassis_sn=" s[1]
        }
        block == 2 && /PID:/ {
            match($0, /PID:[[:space:]]*([^[:space:]]+)/, p)
            match($0, /SN:[[:space:]]*([^[:space:]]+)/, s)
            print "sfp_pid=" p[1]
            print "sfp_sn=" s[1]
            exit
        }
    ' <<< "$inv")

    SW_SERIAL=$(grep  'chassis_sn=' <<< "$parsed_inv" | cut -d= -f2)
    SW_SFP_PID=$(grep 'sfp_pid='   <<< "$parsed_inv" | cut -d= -f2)
    SW_SFP_SN=$(grep  'sfp_sn='    <<< "$parsed_inv" | cut -d= -f2)
    [[ -z "$SW_SERIAL"  ]] && SW_SERIAL="N/A"
    [[ -z "$SW_SFP_PID" ]] && SW_SFP_PID="N/A"
    [[ -z "$SW_SFP_SN"  ]] && SW_SFP_SN="N/A"
}

discover_cameras() {
    CAMERAS=()
    local raw
    raw=$(kee camera detect 2>/dev/null || true)
    [[ -z "$raw" ]] && { warn "kee camera detect: no output."; return 0; }

    # Actual column order (row# ip iface mac last_seen[3words] state vendor[1-N words] hostname):
    #   $1=row#  $2=ip  $3=iface  $4=mac  $5-$7=last_seen  $8=state  $9..$(NF-1)=vendor  $NF=hostname
    # Hostname encodes make/model/serial: last segment=serial, second-to-last=model
    local in_section=0
    while IFS= read -r line; do
        [[ "$line" =~ [Nn]etwork[[:space:]][Dd]evices ]] && { in_section=1; continue; }
        [[ $in_section -eq 0 ]]  && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ [[:space:]]ip[[:space:]] ]] && continue

        local parsed
        parsed=$(awk '
            NF > 8 {
                ip=$2; mac=$4;
                state=$8; gsub(/[(),]/,"",state);
                hostname=$NF;
                vendor=""; for(i=9;i<=NF-1;i++) vendor=vendor (i>9?" ":"") $i;
                n=split(hostname,parts,"-");
                serial=(n>=1) ? parts[n]   : "N/A";
                model =(n>=2) ? parts[n-1] : "N/A";
                print ip "|" mac "|" state "|" vendor "|" hostname "|" model "|" serial
            }
        ' <<< "$line")

        [[ -z "$parsed" ]] && continue
        [[ "$parsed" =~ ^[0-9]+\. ]] || continue
        # Skip the switch — already captured separately
        [[ "$parsed" == "${SW_IP}|"* ]] && continue
        CAMERAS+=("$parsed")
    done <<< "$raw"
}

run_discovery() {
    clear
    printf "\n${B}${CY}  SR SITE INSTALL INVENTORY${R}\n\n"
    info "Running auto-discovery..."
    printf "\n"
    discover_server       && info "Server:  ${SRV_MAKE} ${SRV_MODEL} [${SRV_SERIAL}]"
    discover_switch       && info "Switch:  ${SW_IP} (${SW_HOST})"
    discover_switch_serial && info "Switch serial: ${SW_SERIAL}"
    discover_cameras      && info "Cameras: ${#CAMERAS[@]} found"
    printf "\n"
    sleep 1
}

# ── User prompts ──────────────────────────────────────────────────────────────
wt_input() {  # wt_input "Title" "Prompt" "default"
    whiptail --inputbox "$2" 9 62 "$3" --title "$1" 3>&1 1>&2 2>&3
}

prompt_user() {
    local val
    val=$(wt_input "Personnel" "Onsite technician name:"         "${TECH_NAME}")  && TECH_NAME="$val"  || true
    val=$(wt_input "Personnel" "Sportradar support contact:"     "${SR_CONTACT}") && SR_CONTACT="$val" || true
    val=$(wt_input "Job Info"  "Job / ticket number (optional):" "${JOB_NUM}")    && JOB_NUM="$val"    || true
    val=$(wt_input "Notes"     "Additional notes (optional):"    "${NOTES}")      && NOTES="$val"      || true
}

# ── Camera sort: Allied first, multi-device vendors next, singles last ────────
sorted_cameras() {
    [[ ${#CAMERAS[@]} -eq 0 ]] && return
    declare -A vc
    for c in "${CAMERAS[@]}"; do
        IFS='|' read -r _ _ _ v _ _ _ <<< "$c"
        vc["$v"]=$(( ${vc["$v"]:-0} + 1 ))
    done
    for c in "${CAMERAS[@]}"; do
        IFS='|' read -r _ _ _ v _ _ _ <<< "$c"
        local key
        if   [[ "$v" == *Allied* ]];        then key=1
        elif [[ ${vc["$v"]} -gt 1 ]];       then key=2
        else                                      key=3
        fi
        printf '%s|%s\n' "$key" "$c"
    done | sort -t'|' -k1,1 -k5,5 | cut -d'|' -f2-
}

# ── Report display ────────────────────────────────────────────────────────────
render_report() {
    clear
    hr
    printf "${B}${CY}  SPORTRADAR — SITE INSTALL REPORT${R}\n"
    hr

    section "INSTALL INFO"
    field "Location"  "${LOCATION}"
    field "Date"      "${INST_DATE}"
    [[ -n "$JOB_NUM" ]] && field "Job #" "${JOB_NUM}"

    section "SERVER"
    field "Make"    "${SRV_MAKE}"
    field "Model"   "${SRV_MODEL}"
    field "Serial"  "${SRV_SERIAL}"
    field "IP"      "${SRV_IP}"
    field "NIC MAC" "${SRV_NIC_MAC}"

    section "NETWORK SWITCH"
    field "IP"           "${SW_IP}"
    field "MAC"          "${SW_MAC}"
    field "Hostname"     "${SW_HOST}"
    field "Manufacturer" "${SW_MFR}"
    field "Serial"       "${SW_SERIAL}"
    field "SFP Model"    "${SW_SFP_PID}"
    field "SFP Serial"   "${SW_SFP_SN}"

    section "NETWORK DEVICES  (${#CAMERAS[@]} via kee camera detect)"
    if [[ ${#CAMERAS[@]} -eq 0 ]]; then
        printf "   ${YL}None detected${R}\n"
    else
        local idx=0
        while IFS= read -r cam; do
            idx=$((idx+1))
            IFS='|' read -r ci cm cst cv ch cmo cse <<< "$cam"
            printf "   ${B}%2d.${R} %-15s %s\n" "$idx" "$ci" "$ch"
            printf "       ${B}Vendor:${R} %-30s ${B}Model:${R} %-12s ${B}Serial:${R} %s\n" \
                "$cv" "$cmo" "$cse"
        done < <(sorted_cameras)
    fi

    section "PERSONNEL"
    field "Onsite Tech" "${TECH_NAME:-—}"
    field "SR Support"  "${SR_CONTACT:-—}"

    if [[ -n "$NOTES" ]]; then
        section "NOTES"
        printf "   %s\n" "${NOTES}"
    fi

    printf "\n"
    hr
    printf "\n"
    read -rp "  Press Enter for action menu..." _
}

# ── Edit a field ──────────────────────────────────────────────────────────────
edit_field() {
    local choice
    choice=$(whiptail --menu "Select field to edit:" 24 62 14 \
        "1"  "Onsite Tech:     ${TECH_NAME}"      \
        "2"  "SR Contact:      ${SR_CONTACT}"     \
        "3"  "Job Number:      ${JOB_NUM}"        \
        "4"  "Notes:           ${NOTES:0:30}"     \
        "5"  "Location:        ${LOCATION}"       \
        "6"  "Server Make:     ${SRV_MAKE}"       \
        "7"  "Server Model:    ${SRV_MODEL}"      \
        "8"  "Server Serial:   ${SRV_SERIAL}"     \
        "9"  "Server IP:       ${SRV_IP}"         \
        "10" "Server NIC MAC:  ${SRV_NIC_MAC}"    \
        "11" "Switch IP:       ${SW_IP}"          \
        "12" "Switch MAC:      ${SW_MAC}"         \
        "13" "Switch Serial:   ${SW_SERIAL}"      \
        "14" "Switch MFR:      ${SW_MFR}"         \
        --title "Edit Field" 3>&1 1>&2 2>&3) || return 0

    local val
    case "$choice" in
        1)  val=$(wt_input "Edit" "Onsite Tech Name:"    "${TECH_NAME}")    && TECH_NAME="$val"    || true ;;
        2)  val=$(wt_input "Edit" "SR Support Contact:"  "${SR_CONTACT}")   && SR_CONTACT="$val"   || true ;;
        3)  val=$(wt_input "Edit" "Job / Ticket #:"      "${JOB_NUM}")      && JOB_NUM="$val"      || true ;;
        4)  val=$(wt_input "Edit" "Notes:"               "${NOTES}")        && NOTES="$val"        || true ;;
        5)  val=$(wt_input "Edit" "Location:"            "${LOCATION}")     && LOCATION="$val"     || true ;;
        6)  val=$(wt_input "Edit" "Server Make:"         "${SRV_MAKE}")     && SRV_MAKE="$val"     || true ;;
        7)  val=$(wt_input "Edit" "Server Model:"        "${SRV_MODEL}")    && SRV_MODEL="$val"    || true ;;
        8)  val=$(wt_input "Edit" "Server Serial:"       "${SRV_SERIAL}")   && SRV_SERIAL="$val"   || true ;;
        9)  val=$(wt_input "Edit" "Server IP:"           "${SRV_IP}")       && SRV_IP="$val"       || true ;;
        10) val=$(wt_input "Edit" "Server NIC MAC:"      "${SRV_NIC_MAC}")  && SRV_NIC_MAC="$val"  || true ;;
        11) val=$(wt_input "Edit" "Switch IP:"           "${SW_IP}")        && SW_IP="$val"        || true ;;
        12) val=$(wt_input "Edit" "Switch MAC:"          "${SW_MAC}")       && SW_MAC="$val"       || true ;;
        13) val=$(wt_input "Edit" "Switch Serial:"       "${SW_SERIAL}")    && SW_SERIAL="$val"    || true ;;
        14) val=$(wt_input "Edit" "Switch Manufacturer:" "${SW_MFR}")       && SW_MFR="$val"       || true ;;
    esac
}

# ── Markdown builder ──────────────────────────────────────────────────────────
build_md() {
    local out="$1"
    {
        printf "# Sportradar — Site Install Report\n\n"
        printf "| | |\n|---|---|\n"
        printf "| **Location** | %s |\n" "$LOCATION"
        printf "| **Date** | %s |\n"     "$INST_DATE"
        [[ -n "$JOB_NUM" ]] && printf "| **Job #** | %s |\n" "$JOB_NUM"
        printf "\n## Server\n\n"
        printf "| Field | Value |\n|---|---|\n"
        printf "| Make | %s |\n| Model | %s |\n| Serial | %s |\n| IP | %s |\n| NIC MAC | %s |\n\n" \
            "$SRV_MAKE" "$SRV_MODEL" "$SRV_SERIAL" "$SRV_IP" "$SRV_NIC_MAC"
        printf "## Network Switch\n\n"
        printf "| Field | Value |\n|---|---|\n"
        printf "| IP | %s |\n| MAC | %s |\n| Hostname | %s |\n| Manufacturer | %s |\n| Serial | %s |\n| SFP Model | %s |\n| SFP Serial | %s |\n\n" \
            "$SW_IP" "$SW_MAC" "$SW_HOST" "$SW_MFR" "$SW_SERIAL" "$SW_SFP_PID" "$SW_SFP_SN"
        printf "## Network Devices (%d)\n\n" "${#CAMERAS[@]}"
        if [[ ${#CAMERAS[@]} -gt 0 ]]; then
            printf "| Hostname | IP | MAC | Vendor | Model | Serial |\n"
            printf "|---|---|---|---|---|---|\n"
            while IFS= read -r cam; do
                IFS='|' read -r ci cm cst cv ch cmo cse <<< "$cam"
                printf "| %s | %s | %s | %s | %s | %s |\n" \
                    "$ch" "$ci" "$cm" "$cv" "$cmo" "$cse"
            done < <(sorted_cameras)
            printf "\n"
        else
            printf "_No devices detected._\n\n"
        fi
        printf "## Personnel\n\n"
        printf "| Role | Name |\n|---|---|\n"
        printf "| Onsite Tech | %s |\n| SR Support | %s |\n" \
            "${TECH_NAME:-N/A}" "${SR_CONTACT:-N/A}"
        [[ -n "$NOTES" ]] && printf "\n## Notes\n\n%s\n" "$NOTES"
    } > "$out"
}

# ── GitHub Gist upload ────────────────────────────────────────────────────────
upload_gist() {
    local mdfile="$1"
    local fname="sr-report-${LOCATION}-${INST_DATE// /_}.md"

    local pat
    pat=$(whiptail --passwordbox \
        "Enter GitHub Personal Access Token\n(requires 'gist' scope — not stored on disk)" \
        10 64 --title "GitHub Gist Upload" 3>&1 1>&2 2>&3) || return 1
    [[ -z "$pat" ]] && { warn "No token entered — skipping upload."; return 1; }

    local payload
    payload=$(python3 - "$LOCATION" "$INST_DATE" "$fname" "$mdfile" <<'PYEOF'
import json, sys
loc, date, fname, mdfile = sys.argv[1:]
with open(mdfile) as f:
    content = f.read()
data = {
    "description": f"SR Install Report \u2014 {loc} \u2014 {date}",
    "public": False,
    "files": {fname: {"content": content}}
}
print(json.dumps(data))
PYEOF
) || { err "Failed to build upload payload."; return 1; }

    local resp
    resp=$(curl -sf -X POST \
        -H "Authorization: token ${pat}" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/gists \
        -d "$payload") || { err "Upload failed — check token or network."; return 1; }

    GIST_URL=$(python3 -c \
        "import json,sys; print(json.loads(sys.stdin.read()).get('html_url',''))" <<< "$resp")
    [[ -z "$GIST_URL" ]] && { err "Could not parse Gist URL from response."; return 1; }
    return 0
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main() {
    check_deps
    run_discovery
    prompt_user

    local slug="${LOCATION}-${INST_DATE// /_}"
    REPORT_FILE="/tmp/sr-report-${slug}.md"

    while true; do
        render_report
        build_md "$REPORT_FILE"

        local action
        action=$(whiptail --menu "Choose an action:" 13 54 4 \
            "G" "Generate & upload (GitHub Gist)" \
            "E" "Edit a field" \
            "R" "Start over (re-run discovery)" \
            "Q" "Quit" \
            --title " Actions" 3>&1 1>&2 2>&3) || action="Q"

        case "$action" in
            G)
                if upload_gist "$REPORT_FILE"; then
                    clear
                    printf "\n${B}${GR}  Report uploaded!${R}\n\n"
                    printf "  ${B}Gist URL:${R}   %s\n"   "$GIST_URL"
                    printf "  ${B}Local copy:${R} %s\n\n" "$REPORT_FILE"
                    local next
                    next=$(whiptail --menu "What next?" 10 50 2 \
                        "X" "Exit" \
                        "R" "Start over (new report)" \
                        --title "Done" 3>&1 1>&2 2>&3) || next="X"
                    if [[ "$next" == "R" ]]; then
                        run_discovery
                        prompt_user
                        slug="${LOCATION}-${INST_DATE// /_}"
                        REPORT_FILE="/tmp/sr-report-${slug}.md"
                    else
                        clear
                        printf "\n${B}${CY}  Thanks — report saved to:${R}\n\n"
                        printf "  ${B}%s${R}\n\n" "$REPORT_FILE"
                        exit 0
                    fi
                else
                    printf "\n  ${B}Local copy saved:${R} %s\n\n" "$REPORT_FILE"
                    read -rp "  Press Enter to continue..."
                fi
                ;;
            E)  edit_field ;;
            R)
                run_discovery
                prompt_user
                local slug="${LOCATION}-${INST_DATE// /_}"
                REPORT_FILE="/tmp/sr-report-${slug}.md"
                ;;
            Q)
                build_md "$REPORT_FILE"
                clear
                printf "\n${B}${CY}  Thanks — report saved to:${R}\n\n"
                printf "  ${B}%s${R}\n\n" "$REPORT_FILE"
                exit 0
                ;;
        esac
    done
}

main "$@"
