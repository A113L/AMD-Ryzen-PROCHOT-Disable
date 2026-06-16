# oc_manual.sh — Incremental OC Stability Tester

A companion to [`disable_prochot_mode.sh`](disable_prochot_mode.sh) for
**finding** a stable frequency/voltage combination on a desktop Ryzen
5 3600 (Matisse), rather than just applying one you already know. It
logs every attempt *before* applying it, so if the system hangs, the
log on disk already shows you exactly which combination it was testing
when it died.

> [!WARNING]
> PROCHOT is disabled while this script runs. Read
> [`Warning-Bricked-CPU-Overheating`](README.md)
> before using it — the same risks documented there for
> `disable_prochot_mode.sh` apply here, and this script is specifically
> designed to probe the edges of stability, which means hangs and hard
> resets are an *expected* outcome of normal use, not just a failure mode.

## Relationship to disable_prochot_mode.sh

`disable_prochot_mode.sh` applies one known frequency/VID pair you
already trust. `oc_manual.sh` is the tool for working out what that pair
should be in the first place — either by testing one combination at a
time, or by walking a whole frequency range automatically and stopping
at the first one that fails.

## Requirements

Same as `disable_prochot_mode.sh`:

- A desktop AM4 Ryzen CPU (tested on Ryzen 5 3600 / Matisse)
- The `ryzen_smu` kernel module, loaded (`lsmod | grep ryzen_smu`)
- Root privileges

## Modes

### 1. Single test

Apply one specific frequency/VID pair and run a stress test against it:

```bash
sudo ./oc_manual.sh --freq 3800 --vid 54
```

### 2. Sequence test

Walk a range of frequencies automatically, stepping voltage down
(VID number down, voltage up) at each step, and stop at the first
frequency that fails its stress test:

```bash
sudo ./oc_manual.sh --sequence --start-freq 3600 --stop-freq 3900 --step-freq 100
```

### 3. Show the recommended VID table

```bash
sudo ./oc_manual.sh --list-vid
```

### 4. Dry run

Add `--dry-run` to either single or sequence mode to print exactly what
would be applied and in what order, without touching the SMU or running
any stress test:

```bash
sudo ./oc_manual.sh --sequence --start-freq 3600 --stop-freq 4200 --dry-run
```

## Options

| Flag | Applies to | Default | Meaning |
|---|---|---|---|
| `--freq MHZ` | single mode | — (required) | Frequency to test |
| `--vid VID` | single mode | — (required) | VID to test |
| `--sequence` | — | off | Switch to sequence mode |
| `--start-freq MHZ` | sequence | 3600 | First frequency in the sweep |
| `--stop-freq MHZ` | sequence | 4200 | Last frequency in the sweep (hard cap, also enforced for single mode) |
| `--step-freq MHZ` | sequence | 100 | Frequency increment per step |
| `--vid-start VID` | sequence | 85 (for 3600 MHz) | VID used for the first step; overrides the built-in linear model |
| `--vid-step VID` | sequence | 8 | How much the VID number drops (voltage rises) per frequency step |
| `--no-test` | both | off | Skip the stress test, just apply and move on |
| `--dry-run` | both | off | Print the plan/commands without sending anything to the SMU |
| `--log FILE` | both | `/var/log/oc_manual.log` | Where attempts are logged |
| `--list-vid` | — | — | Print the recommended VID table and exit |

VID is bounded to 0–255, with a hard floor at VID 40 (≈1.3 V) enforced
in both modes — lower VID numbers (higher voltage) are rejected outright
as a sustained-voltage safety cap, not a guarantee anything up to that
point is safe on your specific chip.

## ⚠️ Important: the sequence default doesn't match the recommended table

These are two independent things and they don't agree with each other:

- `--list-vid` prints a **recommended table** starting at VID 70
  (≈1.11 V) for 3600 MHz.
- `--sequence` with no `--vid-start`/`--vid-step` overrides instead uses
  a **built-in linear model** starting at VID 85 (≈1.02 V) for 3600 MHz
  and dropping by 8 per 100 MHz step.

Neither of these matches the VID 103 (0.90625 V) at 3600 MHz that was
already confirmed stable using `disable_prochot_mode.sh` on this exact
chip — both are more conservative (lower starting frequency confidence,
different voltage curve), since they're generic starting points, not
tuned to this CPU.

If you want the sequence to build on what you already know works,
explicitly pass your own confirmed values rather than relying on either
default, e.g.:

```bash
sudo ./oc_manual.sh --sequence --start-freq 3600 --vid-start 103 --vid-step 8
```

Always check `--dry-run` output first to see exactly which frequency/VID
pairs a given set of flags will actually generate before running it for
real.

## Logging

Every attempt is timestamped and appended to the log file (default
`/var/log/oc_manual.log`, override with `--log`) **before** the
corresponding SMU commands are sent, specifically so that a hang still
leaves a usable trail — the last line in the log is the combination that
was being applied when the system stopped responding.

## Sequence behavior on failure

In sequence mode, each step is applied, frequencies are shown, then a
stress test runs. If the stress test reports a non-zero exit (likely
instability) or doesn't even get that far because the system hangs:

- A logged stress test failure stops the sequence cleanly with a `WARN`
  entry and exit code 1 — the last successful step is the one to treat
  as your real result.
- An actual hang means the sequence obviously stops too, but uncleanly
  — that's what the log file is for, since nothing further gets written
  to it after the line for the combination that froze the machine.

## After finding a stable point

Once a frequency/VID pair survives a sequence step (or a single test)
under sustained load, that's the pair to hand to
`disable_prochot_mode.sh --freq <MHZ> --vid <VID>` for normal day-to-day
use, rather than re-running `oc_manual.sh` every boot.

## Disclaimer

Provided as-is. Use at your own risk. Overclocking with PROCHOT disabled
can permanently damage hardware if cooling is inadequate or an unstable
combination is sustained under load. Neither this project nor its
author(s) are responsible for hardware damage, data loss, or warranty
voidance resulting from its use.
