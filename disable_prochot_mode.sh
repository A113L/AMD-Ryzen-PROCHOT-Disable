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

# Allow skipping the stress-ng load test, e.g. when run unattended at boot
# from a systemd service: disable_prochot_mode.sh --no-test
SKIP_TEST=0
if [ "${1:-}" == "--no-test" ]; then
    SKIP_TEST=1
fi

DRV="/sys/kernel/ryzen_smu_drv"

if [ ! -d "$DRV" ]; then
    echo "Error: $DRV not found. Is the ryzen_smu module loaded?"
    echo "Check with: lsmod | grep ryzen_smu"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Please run: sudo $0"
    exit 1
fi

# ----------------------------------------------------------------------
# send_smu_cmd – sends a 24‑byte little‑endian argument and a command byte
#   $1 : argument (decimal, up to 64‑bit)
#   $2 : command ID (hex, e.g., '5a')
#   $3 : label for logging
# ----------------------------------------------------------------------
send_smu_cmd() {
    local arg_dec="$1"
    local cmd_hex="$2"
    local label="$3"

    # Convert the decimal argument to a 48‑character (24‑byte) hex string,
    # reverse byte‑wise (little‑endian), write to smu_args.
    printf '%0*x' 48 "$arg_dec" | fold -w2 | tac | tr -d '\n' | xxd -r -p > "$DRV/smu_args"
    # Send the command byte.
    printf "\\x${cmd_hex}" > "$DRV/rsmu_cmd"

    # Read the 4‑byte status response (little‑endian).
    local status
    status=$(xxd -p "$DRV/rsmu_cmd" | tr -d '\n')

    if [ "$status" == "01000000" ]; then
        echo "[OK]    $label (arg=$arg_dec, cmd=0x$cmd_hex)"
    else
        echo "[FAIL]  $label (arg=$arg_dec, cmd=0x$cmd_hex) -> status=0x$status"
    fi
}

# ----------------------------------------------------------------------
# Helper: display current CPU frequencies (all unique values)
# ----------------------------------------------------------------------
show_freqs() {
    echo "CPU frequencies from /proc/cpuinfo:"
    grep MHz /proc/cpuinfo | sort -u || true
    echo
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
echo "==========================================="
echo " AMD Ryzen Creator Mode Profile Applier"
echo "==========================================="
echo

echo "--- Current state ---"
show_freqs

# Optional: reset any previous manual OC state.
# DisableOverclocking (0x5B, argument 0x1000000 = 16777216)
send_smu_cmd 16777216 5b "DisableOverclocking (cleanup)"

echo
echo "--- Enabling manual overclocking ---"
# EnableOverclocking (0x5A, argument 0)
send_smu_cmd 0 5a "EnableOverclocking"

echo
echo "--- Setting limits (PPT/TDC/EDC) ---"
send_smu_cmd 1000000 53 "SetPPTLimit 1000W"
send_smu_cmd 114000  54 "SetTDCLimit 114A"
send_smu_cmd 168000  55 "SetEDCLimit 168A"

echo
echo "--- Setting VID and all‑core frequency ---"
# VID = 103 → 1.55 - 103*0.00625 = 0.90625V
send_smu_cmd 103  61 "SetOverclockCPUVID (0.90625V)"
send_smu_cmd 3600 5c "SetOverclockFreqAllCores 3600MHz"

echo
echo "--- Disabling PROCHOT ---"
# SetPROCHOTStatus Disabled (0x5A, argument 0x1000000 = 16777216)
send_smu_cmd 16777216 5a "SetPROCHOTStatus Disabled"

echo
echo "--- New state (idle) ---"
sleep 1
show_freqs

# ----------------------------------------------------------------------
# Quick load test (optional)
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
    echo "Install with: sudo apt install stress-ng"
fi

echo
echo "==========================================="
echo " Profile applied. These settings are NOT"
echo " persistent across reboots. Run this script"
echo " again after each boot."
echo "==========================================="
