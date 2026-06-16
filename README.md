# AMD Ryzen 5 3600 6-Core Processor PROCHOT Disable

# ⚠️ Warning: Risk of CPU Damage from Overheating

This page exists because of a real incident: after a thermal event
triggered PROCHOT on this CPU, the clock speed never recovered on its — the CPU stayed stuck running at a few hundred MHz, even
at full load, and combination of reboots, BIOS resets, or governor changes
not brought it back to normal frequencies until the SMU state was forced with this script. In other words, **disabling PROCHOT removes a
core thermal safety feature of your CPU**, but PROCHOT itself can also
leave the chip in a degraded, stuck-low-frequency state that's hard to
recover from through normal means. Read this before you run
`disable_prochot_mode.sh`.

## What PROCHOT actually does

PROCHOT ("Processor Hot") is the AMD SMU's hardware thermal-throttling
signal. When core temperature approaches the silicon's safe limit
(`Tj,max`, typically around 95 °C on Matisse/Ryzen 5 3600), PROCHOT fires
and the CPU automatically clocks down or pauses to bring temperatures back
under control — even if the OS, BIOS, or any monitoring software has
crashed, frozen, or isn't running at all.

This script disables that signal (`SetPROCHOTStatus Disabled`) so the
chip can sustain higher all-core clocks without being throttled back. That
is the entire point of "Creator Mode"-style profiles — but it also means
**the one hardware-level safeguard standing between a cooling failure and
permanent CPU damage is turned off.**

## What can actually go wrong

With PROCHOT disabled and the PPT/TDC/EDC limits raised (this profile sets
PPT to 1000 W, i.e. effectively unlimited), nothing in hardware will stop
the chip from drawing power and generating heat past its safe thermal
limit if:

- your cooler isn't seated correctly, has dried-out thermal paste, or its
  fan/pump fails
- case airflow is inadequate for sustained full-load operation
- you suspend/resume or hot-plug a cooler (e.g. AIO) while the profile is
  still active
- the system is left under sustained load (renders, exports, compiles,
  stress tests) unattended

Sustained operation above the silicon's safe temperature can cause:

- **Thermal throttling failure leading to a hard shutdown** (best case —
  the motherboard's own independent thermal protection, where present,
  kicks in instead)
- **Electromigration and accelerated silicon degradation**, shortening
  the CPU's usable lifespan even if it doesn't fail outright
- **Permanent damage to the CPU die, IHS solder, or socket/VRM
  components** in sustained worst-case scenarios — colloquially, a
  "bricked" or degraded CPU that no longer boots reliably or develops
  instability under load
- **Collateral damage to the motherboard VRM**, since this profile also
  raises TDC/EDC current limits well above stock

AMD's own warranty terms generally exclude damage caused by operating
outside rated specifications, including disabled protection features like
PROCHOT — so this is also a **warranty risk**, not just a hardware risk.

## This is not theoretical

This class of failure is precisely why PROCHOT exists in the first place,
and disabling it is explicitly called out as a high-risk action in AMD
Ryzen Master's own UI when toggling similar settings. Running with it
disabled is safe *only* for as long as your cooling solution keeps up —
there is no longer a hardware fallback if it doesn't.

## The ryzen_smu kernel module

[`ryzen_smu`](https://github.com/leogx9r/ryzen_smu) is a third-party
Linux kernel module that exposes a raw interface to the SMU (System
Management Unit) — the embedded controller on the CPU package that
actually governs power limits, voltages, clocks, and PROCHOT. Once
loaded, it creates `/sys/kernel/ryzen_smu_drv/`, with two files this
script writes to directly:

- `smu_args` — a 24-byte argument buffer, written little-endian, that
  holds the parameter for whatever command is about to be sent
- `rsmu_cmd` — writing a single command-ID byte here tells the SMU to
  execute that command using whatever is currently in `smu_args`; the
  response status is read back from the same file

There is no abstraction layer here: this module talks straight to the
SMU's mailbox protocol, which is exactly why it can do things no other
Linux tool can (see above), and also why a wrong command ID or argument
on the wrong silicon is genuinely capable of misconfiguring the chip.

### Installing ryzen_smu

```bash
sudo apt install -y git build-essential linux-headers-$(uname -r) dkms
git clone https://github.com/leogx9r/ryzen_smu.git
cd ryzen_smu
make -j$(nproc)
sudo make install
sudo modprobe ryzen_smu
```

Verify it loaded:

```bash
lsmod | grep ryzen_smu
ls /sys/kernel/ryzen_smu_drv/
```

`make install` does not make the module load automatically at boot, and
won't survive a kernel upgrade on its own. To persist it:

```bash
# simplest, current kernel only
echo ryzen_smu | sudo tee /etc/modules-load.d/ryzen_smu.conf
sudo depmod -a
```

or, if the repo ships a `dkms.conf`, install it through DKMS instead so
it rebuilds automatically for future kernels.

## SMU commands this script sends

Each line below corresponds directly to a `send_smu_cmd` call in
`disable_prochot_mode.sh`. Command IDs and the VID/frequency encoding
are specific to the SMU mailbox on Matisse (Zen 2) desktop parts — do
not assume these same IDs are safe on other silicon.

| Command (script label) | Cmd ID | Argument | What it does |
|---|---|---|---|
| `DisableOverclocking (cleanup)` | `0x5b` | `16777216` (`0x1000000`) | Resets any prior manual OC state before applying a fresh profile |
| `EnableOverclocking` | `0x5a` | `0` | Switches the SMU into manual overclocking mode |
| `SetPPTLimit` | `0x53` | `1000000` (mW) | Sets the package power limit — 1000 W here, i.e. effectively removed |
| `SetTDCLimit` | `0x54` | `114000` (mA) | Sets the sustained current limit to 114 A |
| `SetEDCLimit` | `0x55` | `168000` (mA) | Sets the peak/transient current limit to 168 A |
| `SetOverclockCPUVID` | `0x61` | `103` | Fixes core voltage via VID; `1.55 − 103×0.00625 = 0.90625 V` |
| `SetOverclockFreqAllCores` | `0x5c` | `3600` (MHz) | Locks all cores to a fixed 3600 MHz, disabling per-core boost |
| `SetPROCHOTStatus Disabled` | `0x5a` | `16777216` (`0x1000000`) | Disables the PROCHOT thermal-throttling signal — see above |

Note that `EnableOverclocking` and `SetPROCHOTStatus` share command ID
`0x5a` but are distinguished by the argument value sent.

## Installing the autostart service

Because the profile is volatile and must be re-applied every boot, the
repo includes `disable_prochot_mode.service`, a oneshot systemd unit
that runs the script automatically once `ryzen_smu` is loaded.

```bash
sudo install -m 755 disable_prochot_mode.sh /usr/local/sbin/disable_prochot_mode.sh
sudo install -m 644 disable_prochot_mode.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now disable_prochot_mode.service
```

Check it:

```bash
systemctl status disable_prochot_mode.service
journalctl -u disable_prochot_mode.service -b
```

A healthy status after reboot looks like this (the unit exits once the
profile is applied; `RemainAfterExit` is what keeps it shown as active):

```
● disable_prochot_mode.service - Apply AMD Ryzen Creator Mode OC profile (ryzen_smu)
   Loaded: loaded (/etc/systemd/system/disable_prochot_mode.service; enabled; vendor preset: enabled)
   Active: active (exited) since ...; 18 minutes ago
   Main PID: 944 (code=exited, status=0/SUCCESS)
   ...
   Profile applied. These settings are NOT
   persistent across reboots. Run this script
   again after each boot.
   systemd[1]: Finished Apply AMD Ryzen Creator Mode OC profile (ryzen_smu).
```

`active (exited)` + `status=0/SUCCESS` confirms the script ran
successfully once at boot, which is the expected state for this oneshot
unit.

Given everything above, think carefully before enabling this service on
a machine you don't actively monitor: it means the PROCHOT-disabled,
power-unlimited profile gets applied unattended on every single boot,
with no one watching to catch a cooling problem.

## Minimum precautions if you still want to use this profile

- Verify your cooler is properly mounted with fresh thermal paste before
  enabling this profile, not after.
- Monitor temperatures continuously while under load (`sensors`, `lm-sensors`,
  or `k10temp` readings) — at least until you've validated stability with a
  longer stress test than this script's default 10-second sample.
- Never leave the system unattended under sustained heavy load the first
  several times you run this profile.
- Set a manual software-based temperature cutoff/alarm if your monitoring
  tooling supports one, since hardware-level PROCHOT throttling is no
  longer available as a backstop.
- Re-enable PROCHOT (`DisableOverclocking`, as this script's cleanup step
  already does on the *next* run) if you're not actively using the high
  all-core profile.
- Don't run this automatically at every boot (e.g. via the included
  systemd service) on a machine you don't actively monitor.

## Disclaimer

This script and profile are provided as-is, for users who understand and
accept the risks above. Neither the script's author nor this
repository are responsible for hardware damage, data loss, or warranty
voidance resulting from its use. If you are not confident in your
cooling solution or unsure what these settings do, do not disable
PROCHOT.
