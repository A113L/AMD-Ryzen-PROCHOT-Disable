#!/bin/bash
#
# oc_test.sh - Incremental OC stability test for Ryzen 5 3600 (Matisse)
#              using the ryzen_smu kernel module.
#
# This script logs every attempt BEFORE applying settings, so if your
# system hangs you can check the log to see the last failing combination.
# Stress-testing is optional but highly recommended.
#
# Usage:
#   Single setting: sudo ./oc_test.sh --freq MHZ --vid VID [--no-test] [--log FILE]
#   Sequence:       sudo ./oc_test.sh --sequence [OPTIONS] [--no-test] [--log FILE]
#   Show table:     sudo ./oc_test.sh --list-vid
#   Dry run:        add --dry-run to either mode to see what would happen.
#
# Sequence options (all optional, with defaults):
#   --start-freq MHZ    Default: 3600
#   --stop-freq  MHZ    Default: 4200
#   --step-freq  MHZ    Default: 100
#   --vid-start  VID    Start VID for the first frequency (default: 85)
#                       Overrides the linear formula.
#   --vid-step   VID    Decrease VID by this amount per frequency step
#                       (lower VID = higher voltage). Default: 8
#                       (≈ +50 mV per 100 MHz)
#
# If --vid-start is not given, the script uses a linear model starting at
# VID 85 for 3600 MHz. Use --list-vid to see a table of recommended,
# more realistic starting points for a typical chip.
#
# WARNING: PROCHOT is disabled during the test. Monitor temperatures
# carefully. Overclocking can permanently damage hardware.
#

set -e

# ----------------------------------------------------------------------
# Recommended VID table (realistic for typical Ryzen 5 3600)
# ----------------------------------------------------------------------
REC_FREQS=(  3600  3700  3800  3900  4000  4100  4200 )
REC_VIDS=(    70    62    54    46    40    40    40 )
# Voltage = 1.55 - VID * 0.00625
# VID floor (40) = 1.30 V. For 4000+ MHz this may be insufficient;
# higher voltages (lower VID) are blocked by the safety cap.

# ----------------------------------------------------------------------
# Default log file
# ----------------------------------------------------------------------
LOG_FILE="/var/log/oc_test.log"

# ----------------------------------------------------------------------
# Global flags
# ----------------------------------------------------------------------
DRY_RUN=0
SKIP_TEST=0
SEQUENCE_MODE=0

# Frequency parameters
START_FREQ=3600
STOP_FREQ=4200
STEP_FREQ=100

# VID parameters (linear model defaults)
VID_START_DEFAULT=85   # for 3600 MHz
VID_STEP_DEFAULT=8     # lower VID per +100 MHz

# Command-line overrides
VID_START=""           # if set, use instead of default linear model
VID_STEP=""

MAX_FREQ=4200
MIN_VID=40    # hard floor (≈1.3 V max); lower VID = higher voltage
MAX_VID=255

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------
log_msg() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Convert VID to voltage
vid_to_voltage() {
    awk "BEGIN {printf \"%.4f\", 1.55 - $1 * 0.00625}"
}

# Display current frequencies
show_freqs() {
    echo "CPU frequencies from /proc/cpuinfo:"
    grep MHz /proc/cpuinfo | sort -u || true
    echo
}

# Send SMU command (same as earlier scripts)
send_smu_cmd() {
    local arg_dec="$1"
    local cmd_hex="$2"
    local label="$3"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] Would send: $label (arg=$arg_dec, cmd=0x$cmd_hex)"
        return
    fi

    printf '%0*x' 48 "$arg_dec" | fold -w2 | tac | tr -d '\n' | xxd -r -p > "$DRV/smu_args"
    printf "\\x${cmd_hex}" > "$DRV/rsmu_cmd"

    local status
    status=$(xxd -p "$DRV/rsmu_cmd" | tr -d '\n')

    if [ "$status" == "01000000" ]; then
        log_msg "OK" "$label"
    else
        log_msg "FAIL" "$label (status=0x$status)"
    fi
}

# Apply a complete profile (enable OC, limits, VID, freq, PROCHOT off)
apply_profile() {
    local vid="$1"
    local freq="$2"
    local voltage
    voltage=$(vid_to_voltage "$vid")

    log_msg "INFO" "Applying profile: ${freq}MHz, VID ${vid} (${voltage}V)"

    # Clean previous state
    send_smu_cmd 16777216 5b "DisableOverclocking (cleanup)"
    # Enable manual OC
    send_smu_cmd 0 5a "EnableOverclocking"
    # Set limits (unchanged)
    send_smu_cmd 1000000 53 "SetPPTLimit 1000W"
    send_smu_cmd 114000  54 "SetTDCLimit 114A"
    send_smu_cmd 168000  55 "SetEDCLimit 168A"
    # VID and frequency
    send_smu_cmd "$vid" 61 "SetOverclockCPUVID (${voltage}V)"
    send_smu_cmd "$freq" 5c "SetOverclockFreqAllCores ${freq}MHz"
    # Disable PROCHOT
    send_smu_cmd 16777216 5a "SetPROCHOTStatus Disabled"
}

# Run stress test (if not skipped)
run_stress_test() {
    if [ "$SKIP_TEST" -eq 1 ]; then
        log_msg "INFO" "Stress test skipped (--no-test)"
        return 0
    fi
    if ! command -v stress-ng &> /dev/null; then
        log_msg "WARN" "stress-ng not found – skipping stress test"
        return 0
    fi

    log_msg "INFO" "Starting 15-second stress test..."
    stress-ng --cpu 12 --timeout 15s &
    local stress_pid=$!

    # Show frequencies while under load
    sleep 5
    echo "Frequencies under load:"
    grep MHz /proc/cpuinfo | sort -u
    echo

    wait $stress_pid
    if [ $? -eq 0 ]; then
        log_msg "INFO" "Stress test completed successfully"
        return 0
    else
        log_msg "WARN" "Stress test returned non-zero – possible instability"
        return 1
    fi
}

# Print recommended VID table
show_vid_table() {
    echo "Recommended VID table for typical Ryzen 5 3600 (Matisse):"
    echo
    printf "  %-10s %-5s %-10s %s\n" "Freq(MHz)" "VID" "Voltage" "Note"
    for i in "${!REC_FREQS[@]}"; do
        f="${REC_FREQS[$i]}"
        v="${REC_VIDS[$i]}"
        volt=$(vid_to_voltage "$v")
        note=""
        if [ "$v" -le "$MIN_VID" ]; then
            note="(VID floor – may be unstable, see below)"
        fi
        printf "  %-10s %-5s %-10s %s\n" "$f" "$v" "${volt}V" "$note"
    done
    echo
    echo "This table assumes a \"normal\" chip. If your CPU is degraded (\"bricked\"),"
    echo "start with LOWER frequencies and/or HIGHER voltages (i.e., lower VID numbers)."
    echo "The script enforces a VID floor of ${MIN_VID} (≈1.3 V max). Frequencies above"
    echo "3900 MHz may require voltages above this cap, which are blocked by default."
    echo "For a bricked chip, consider testing only up to 3600-3800 MHz initially."
}

# ----------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --list-vid)
            show_vid_table
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-test)
            SKIP_TEST=1
            shift
            ;;
        --sequence)
            SEQUENCE_MODE=1
            shift
            ;;
        --start-freq)
            START_FREQ="$2"
            shift 2
            ;;
        --start-freq=*)
            START_FREQ="${1#*=}"
            shift
            ;;
        --stop-freq)
            STOP_FREQ="$2"
            shift 2
            ;;
        --stop-freq=*)
            STOP_FREQ="${1#*=}"
            shift
            ;;
        --step-freq)
            STEP_FREQ="$2"
            shift 2
            ;;
        --step-freq=*)
            STEP_FREQ="${1#*=}"
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
        --vid-start)
            VID_START="$2"
            shift 2
            ;;
        --vid-start=*)
            VID_START="${1#*=}"
            shift
            ;;
        --vid-step)
            VID_STEP="$2"
            shift 2
            ;;
        --vid-step=*)
            VID_STEP="${1#*=}"
            shift
            ;;
        --log)
            LOG_FILE="$2"
            shift 2
            ;;
        --log=*)
            LOG_FILE="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage:"
            echo "  Single:   $0 --freq MHZ --vid VID [--no-test] [--log FILE] [--dry-run]"
            echo "  Sequence: $0 --sequence [--start-freq MHZ] [--stop-freq MHZ] [--step-freq MHZ]"
            echo "                         [--vid-start VID] [--vid-step VID] [--no-test] [--dry-run]"
            echo "  Table:    $0 --list-vid"
            echo ""
            echo "Examples:"
            echo "  $0 --list-vid"
            echo "  sudo $0 --freq 3800 --vid 54"
            echo "  sudo $0 --sequence --start-freq 3600 --stop-freq 3900 --step-freq 100"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------
DRV="/sys/kernel/ryzen_smu_drv"
if [ ! -d "$DRV" ]; then
    echo "Error: $DRV not found. Is the ryzen_smu module loaded?" >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root. Run: sudo $0" >&2
    exit 1
fi

# Validate single mode vs sequence mode
if [ "$SEQUENCE_MODE" -eq 0 ]; then
    if [ -z "$FREQ" ] || [ -z "$VID" ]; then
        echo "Error: single mode requires --freq and --vid" >&2
        exit 1
    fi
fi

# Validate frequencies
if [ "$START_FREQ" -gt "$MAX_FREQ" ] || [ "$STOP_FREQ" -gt "$MAX_FREQ" ]; then
    echo "Error: Frequency above cap ($MAX_FREQ MHz)" >&2
    exit 1
fi

# Validate VID for single mode
if [ -n "$VID" ]; then
    if [ "$VID" -lt "$MIN_VID" ] || [ "$VID" -gt "$MAX_VID" ]; then
        echo "Error: VID out of range ($MIN_VID-$MAX_VID)" >&2
        exit 1
    fi
fi

# ----------------------------------------------------------------------
# Single mode
# ----------------------------------------------------------------------
if [ "$SEQUENCE_MODE" -eq 0 ]; then
    log_msg "INFO" "=== Single test ==="
    log_msg "INFO" "Target: ${FREQ}MHz, VID ${VID} ($(vid_to_voltage "$VID")V)"
    show_freqs
    apply_profile "$VID" "$FREQ"
    sleep 1
    show_freqs
    run_stress_test
    log_msg "INFO" "Test completed. If you see this, the system survived."
    exit 0
fi

# ----------------------------------------------------------------------
# Sequence mode
# ----------------------------------------------------------------------
# Determine VID start and step
if [ -z "$VID_START" ]; then
    VID_START=$VID_START_DEFAULT
fi
if [ -z "$VID_STEP" ]; then
    VID_STEP=$VID_STEP_DEFAULT
fi

log_msg "INFO" "=== Sequence test ==="
log_msg "INFO" "Range: ${START_FREQ}-${STOP_FREQ} MHz, step ${STEP_FREQ} MHz"
log_msg "INFO" "VID model: start=${VID_START}, step=${VID_STEP} (lower = higher voltage)"

# Build sequence
freqs=()
vids=()
current_freq=$START_FREQ
current_vid=$VID_START
steps=0

while [ "$current_freq" -le "$STOP_FREQ" ]; do
    if [ "$current_vid" -lt "$MIN_VID" ]; then
        log_msg "WARN" "VID ${current_vid} for ${current_freq}MHz is below floor (${MIN_VID}) – stopping sequence."
        break
    fi
    freqs+=("$current_freq")
    vids+=("$current_vid")
    current_freq=$(( current_freq + STEP_FREQ ))
    current_vid=$(( current_vid - VID_STEP ))
    steps=$(( steps + 1 ))
done

if [ $steps -eq 0 ]; then
    log_msg "ERROR" "No valid steps generated. Check frequencies and VID floor."
    exit 1
fi

# Dry-run: print plan and exit
if [ "$DRY_RUN" -eq 1 ]; then
    log_msg "DRY-RUN" "Planned sequence:"
    for i in "${!freqs[@]}"; do
        v=$(vid_to_voltage "${vids[$i]}")
        echo "  Step $((i+1)): ${freqs[$i]} MHz, VID ${vids[$i]} (${v}V)"
    done
    exit 0
fi

# Execute sequence
for i in "${!freqs[@]}"; do
    f="${freqs[$i]}"
    v="${vids[$i]}"

    log_msg "INFO" "========== Step $((i+1))/${#freqs[@]} : ${f}MHz, VID ${v} ========="
    show_freqs

    log_msg "INFO" "Applying: ${f}MHz, VID ${v} ($(vid_to_voltage "$v")V)"
    apply_profile "$v" "$f"

    sleep 1
    show_freqs

    if ! run_stress_test; then
        log_msg "WARN" "Stopping sequence due to stress test failure/instability."
        exit 1
    fi

    echo ""
done

log_msg "INFO" "=== Sequence finished successfully ==="
echo "All steps passed. Check the log: $LOG_FILE"
