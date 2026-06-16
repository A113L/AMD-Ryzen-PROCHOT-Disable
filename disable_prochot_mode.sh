#!/bin/bash
#
# disable_prochot_mode.sh
#
# Replicates the "Creator Mode" profile from AMD Ryzen Master
# for a Ryzen 5 3600 (Matisse) using the ryzen_smu kernel module.
#
# ----------------------------------------------------------------------
# REQUIREMENTS: ryzen_smu kernel module
# ----------------------------------------------------------------------
#   This script needs the ryzen_smu module loaded to expose the SMU
#   command/argument interface under /sys/kernel/ryzen_smu_drv/.
#
#   Install it:
#     sudo apt install -y git build-essential linux-headers-$(uname -r) dkms
#     git clone https://github.com/leogx9r/ryzen_smu.git
#     cd ryzen_smu
#     make -j$(nproc)
#     sudo make install
#     sudo modprobe ryzen_smu
#
#   Verify it loaded:
#     lsmod | grep ryzen_smu
#     ls /sys/kernel/ryzen_smu_drv/
#
# ----------------------------------------------------------------------
# MAKE ryzen_smu LOAD AUTOMATICALLY ON BOOT
# ----------------------------------------------------------------------
#   "make install" above places the module under /lib/modules/$(uname -r)/
#   and runs depmod, but it will NOT auto-load at boot by itself, and a
#   plain "make install" build won't survive a kernel upgrade. Pick one:
#
#   Option A — simplest (load at boot, current kernel only):
#     echo ryzen_smu | sudo tee /etc/modules-load.d/ryzen_smu.conf
#     sudo depmod -a
#     (reboot to test, or `sudo modprobe ryzen_smu` to load it now)
#
#   Option B — DKMS (recommended, survives kernel updates):
#     If the repo ships a dkms.conf, install it via DKMS instead of a
#     plain make install so it auto-rebuilds for each new kernel:
#       sudo cp -r ryzen_smu /usr/src/ryzen_smu-1.0
#       sudo dkms add -m ryzen_smu -v 1.0
#       sudo dkms build -m ryzen_smu -v 1.0
#       sudo dkms install -m ryzen_smu -v 1.0
#       echo ryzen_smu | sudo tee /etc/modules-load.d/ryzen_smu.conf
#     (If the repo has no dkms.conf, stick with Option A and re-run
#      "make install" after kernel upgrades.)
#
#   Note: this only loads the *module*. The OC/PROCHOT settings applied
#   by THIS script are still volatile and must be re-run after every
#   boot (e.g. via a systemd service or @reboot cron calling this script
#   with sudo, once the module is confirmed loaded).
#
# ----------------------------------------------------------------------
# AUTOSTART THIS SCRIPT'S PROFILE AT BOOT (systemd)
# ----------------------------------------------------------------------
#   Install this script + the included apply-creator-mode.service unit:
#     sudo install -m 755 disable_prochot_mode.sh /usr/local/sbin/disable_prochot_mode.sh
#     sudo install -m 644 disable_prochot_mode.service /etc/systemd/system/
#     sudo systemctl daemon-reload
#     sudo systemctl enable --now disable_prochot_mode.service
#
#   Check it:
#     systemctl status disable_prochot_mode.service
#     journalctl -u disable_prochot_mode.service -b
#
# Requirements:
#   - ryzen_smu module loaded (lsmod | grep ryzen_smu)
#   - Root privileges (sudo)
#
# The profile sets:
#   PPT = 1000 W  (essentially unlimited)
#   TDC = 114 A
#   EDC = 168 A
#   All‑core frequency = 3600 MHz
#   VID = 103  → 1.55 - 103*0.00625 = 0.90625 V
#
# WARNING: These limits are extremely high and are intended only to
# remove power/current restrictions. Do NOT use this profile without
# verifying that your cooling and VRM can handle the load.
#

set -e

# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------
FREQ=3600
VID=103
SKIP_TEST=0

# Safety caps
MAX_FREQ=4200
MIN_VID=40    # ≈ 1.30 V max (lower VID = higher voltage)
MAX_VID=255

# ----------------------------------------------------------------------
# Recommended VID table (typical Ryzen 5 3600)
# ----------------------------------------------------------------------
REC_FREQS=(  3600  3700  3800  3900  4000  4100  4200 )
REC_VIDS=(    70    62    54    46    40    40    40 )

# ----------------------------------------------------------------------
# Functions
# ----------------------------------------------------------------------
show_vid_table() {
    echo "Recommended VID table for typical Ryzen 5 3600 (Matisse):"
    printf "  %-10s %-5s %-10s %s\n" "Freq(MHz)" "VID" "Voltage" "Note"
    for i in "${!REC_FREQS[@]}"; do
        f="${REC_FREQS[$i]}"
        v="${REC_VIDS[$i]}"
        volt=$(awk "BEGIN {printf \"%.4f\", 1.55 - $v * 0.00625}")
        note=""
        [ "$v" -le "$MIN_VID" ] && note="(VID floor – may need >1.3V, blocked by default)"
        printf "  %-10s %-5s %-10s %s\n" "$f" "$v" "${volt}V" "$note"
    done
    echo
    echo "For a degraded (\"bicked\") chip, start at even lower frequencies"
    echo "or higher voltages (lower VID numbers)."
}

show_help() {
    echo "Usage: $0 [--freq MHZ] [--vid VID] [--no-test] [--list-vid]"
    echo
    echo "Apply a manual OC profile on Ryzen 5 3600 via ryzen_smu."
    echo
    echo "Options:"
    echo "  --freq MHZ   All-core frequency (default: 3600, max: $MAX_FREQ)"
    echo "  --vid VID    Voltage ID (default: 103 → 0.90625 V, floor: $MIN_VID → ~1.30 V)"
    echo "  --no-test    Skip the 10s stress-ng test"
    echo "  --list-vid   Print a recommended VID table and exit"
    echo "  --help       Show this help"
}

vid_to_voltage() {
    awk "BEGIN {printf \"%.4f\", 1.55 - $1 * 0.00625}"
}

show_freqs() {
    echo "CPU frequencies from /proc/cpuinfo:"
    grep MHz /proc/cpuinfo | sort -u || true
    echo
}

send_smu_cmd() {
    local arg_dec="$1"
    local cmd_hex="$2"
    local label="$3"

    printf '%0*x' 48 "$arg_dec" | fold -w2 | tac | tr -d '\n' | xxd -r -p > "$DRV/smu_args"
    printf "\\x${cmd_hex}" > "$DRV/rsmu_cmd"

    local status
    status=$(xxd -p "$DRV/rsmu_cmd" | tr -d '\n')

    if [ "$status" == "01000000" ]; then
        echo "[OK]    $label (arg=$arg_dec, cmd=0x$cmd_hex)"
    else
        echo "[FAIL]  $label (arg=$arg_dec, cmd=0x$cmd_hex) -> status=0x$status"
    fi
}

# ----------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --no-test)
            SKIP_TEST=1
            shift
            ;;
        --freq)
            FREQ="$2"
            shift 2
            ;;
        --freq=*)
            FREQ="${1#*=}"
            shift
            ;;
        --vid)
            VID="$2"
            shift 2
            ;;
        --vid=*)
            VID="${1#*=}"
            shift
            ;;
        --list-vid)
            show_vid_table
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--freq MHZ] [--vid VID] [--no-test] [--list-vid]" >&2
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------
if ! [[ "$FREQ" =~ ^[0-9]+$ ]]; then
    echo "Error: --freq must be a positive integer (got: $FREQ)" >&2
    exit 1
fi
if [ "$FREQ" -gt "$MAX_FREQ" ]; then
    echo "Error: --freq ${FREQ} exceeds maximum allowed (${MAX_FREQ} MHz)" >&2
    exit 1
fi

if ! [[ "$VID" =~ ^[0-9]+$ ]]; then
    echo "Error: --vid must be a non-negative integer (got: $VID)" >&2
    exit 1
fi
if [ "$VID" -gt "$MAX_VID" ] || [ "$VID" -lt "$MIN_VID" ]; then
    echo "Error: --vid must be between ${MIN_VID} and ${MAX_VID} (got: $VID)" >&2
    exit 1
fi

VOLTAGE=$(vid_to_voltage "$VID")

# Optional warning if using default VID with non-default frequency
if [ "$FREQ" -ne 3600 ] && [ "$VID" -eq 103 ]; then
    echo "NOTE: Default VID (103 = 0.906 V) was validated only at 3600 MHz." >&2
    echo "Higher frequencies may be unstable. See --list-vid for guidance." >&2
    echo
fi

# ----------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------
DRV="/sys/kernel/ryzen_smu_drv"
if [ ! -d "$DRV" ]; then
    echo "Error: $DRV not found. Is the ryzen_smu module loaded?"
    exit 1
fi
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root. Run: sudo $0"
    exit 1
fi

# ----------------------------------------------------------------------
# Apply profile
# ----------------------------------------------------------------------
echo "==========================================="
echo " AMD Ryzen Creator Mode Profile Applier"
echo " Target: ${FREQ}MHz, VID ${VID} (${VOLTAGE}V)"
echo "==========================================="
echo

echo "--- Current state ---"
show_freqs

# Clean previous OC state
send_smu_cmd 16777216 5b "DisableOverclocking (cleanup)"

echo
echo "--- Enabling manual overclocking ---"
send_smu_cmd 0 5a "EnableOverclocking"

echo
echo "--- Setting limits (PPT/TDC/EDC) ---"
send_smu_cmd 1000000 53 "SetPPTLimit 1000W"
send_smu_cmd 114000  54 "SetTDCLimit 114A"
send_smu_cmd 168000  55 "SetEDCLimit 168A"

echo
echo "--- Setting VID and all-core frequency ---"
send_smu_cmd "$VID" 61 "SetOverclockCPUVID (${VOLTAGE}V)"
send_smu_cmd "$FREQ" 5c "SetOverclockFreqAllCores ${FREQ}MHz"

echo
echo "--- Disabling PROCHOT ---"
send_smu_cmd 16777216 5a "SetPROCHOTStatus Disabled"

echo
echo "--- New state (idle) ---"
sleep 1
show_freqs

# ----------------------------------------------------------------------
# Stress test (optional)
# ----------------------------------------------------------------------
echo "--- Load test (10s stress-ng, if available) ---"
if [ "$SKIP_TEST" -eq 1 ]; then
    echo "Skipped (--no-test)."
elif command -v stress-ng &> /dev/null; then
    stress-ng --cpu 12 --timeout 10s &
    sleep 4
    show_freqs
    wait
else
    echo "stress-ng not installed – skipping load test."
fi

echo
echo "==========================================="
echo " Profile applied. Settings are volatile –"
echo " reapply after every boot."
echo "==========================================="

