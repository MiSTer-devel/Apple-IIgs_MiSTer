# WOZ work — handoff

State as of 2026-09-02. Branch `woz-fixes` (pushed to `alanswx`), tree clean.
Read this first, then `WOZ_FINDINGS.md` for the evidence behind every claim.

## TL;DR

Started from the six WOZ defects in `Apple-II_MiSTer/TODO.md` (Phase 1, item 4).
**Three of the six were misdiagnosed.** Five RTL fixes shipped, the last being
the Disk II sequencer semantics for 5.25" reads, which closed the First Math bug
and four more images. The durable output is the measurement setup: a
verified-good test suite, a known-good reference emulator, and ~15 documented
dead ends.

WOZ Test Images score: **24 of 26 BOOTED** (was 19). Remaining: Hard Hat Mack
and Stargate (GSSquared fails both on `-p 5` too).

## Branches

| Branch | What |
|--------|------|
| `woz-fixes` | all shipped work (this is the one) |
| `woz-separator-wip` | 5.25" data separator, parked — see below |
| `main` | upstream `MiSTer-devel`; fork remote is `alanswx` |

## Shipped fixes

| Commit | Fix |
|--------|-----|
| `a530e43` | weak-bit LFSR advances only on fake-bit consumption (was free-running at 14MHz) |
| `a530e43` | write-back guard: unmapped-track writes no longer flush over the last-loaded track |
| `458dd35` | **Q6H (`$C08D`) resets the read shift register** — makes Commando and Wings of Fury boot |
| `8c4f9d7` | **SmartPort mode bits no longer gate 5.25" flux** — fixes first-sector corruption |
| `d3ab554` | `optimal_bit_timing` honoured (restored after I wrongly reverted it) |
| `72e17ea` | harness passes `--fixed-time` — results are reproducible |
| `ad58d62` | results classified by failure screen, not PNG size |
| (this)    | **5.25" sync reads follow the Disk II sequencer**: QA hold until the next pulse, no clear on read, READLOAD fills with WP sense. First Math, DOS 3.2, ProDOS User's Disk, Border Zone A/B boot |
| (this)    | **1 MHz persists through the 5.25" motor-off holdover** (`iwm_woz` `IWM_ENBL` -> `clock_divider` `disk_motor_hold`, honours mode bit 2). Needed by Bouncing Kamungas once reads stopped clearing on read |

`458dd35`'s known regression, **The Halley Project**, is resolved by the
sequencer change: it matches GSSquared frame-for-frame at 2500 frames. It still
shows BLANK at the corpus harness's 1200 frames (slow loader; the old "BOOTED"
was its loading splash), so retest it with `--frames 2500`.

## Tooling — exact commands

```bash
cd vsim

# WOZ Test Images (26 verified-good images, each isolating one behaviour)
./run_woztest_suite.sh woztest_out 1500 12      # 1500 frames; 400 is NOT enough
VEMU=./obj_dir_lss/Vemu ./run_woztest_suite.sh woztest_out 1500 12   # alternate build

# 202-disk corpus regression (22 odd-timing + 180 controls). ~5.5 h at 12 jobs.
./test_woz_batch.sh --retest verify_p0.txt --jobs 12 --frames 2500 \
                    --timeout 2800 --out woz_out
python3 woz_compare.py woz_out/results.csv woz_ref/results.csv
# woz_ref/ = frozen 2026-09-02 from b78c007 at 2500 frames (175 BOOTED, 25
# TEXT_ONLY, 2 BLANK, 0 TIMEOUT). The 2026-08-28 one is woz_ref_20260828/.
# The status classifier is frame-sensitive: a program that has moved on to a
# name prompt or a demo scores TEXT_ONLY/BLANK, so eyeball every "regression"
# (shots/<hash>.png) before believing it. Same build at 1200 vs 2500 frames
# already flips 18 statuses with zero real change.

# per-defect boot rates against the classification map
python3 woz_join.py woz_out/results.csv

# reference emulator (known-good). MUST use -p 5 (IIgs ROM 01) or -p 6 (ROM 3)
# to match our core; -p 3 is the enhanced //e (65C02) for the IIe port.
cd /home/alans/mister/gssquared-bench
cmake --install build            # REQUIRED; build/GSSquared aborts on a missing font
DISPLAY=:0 LD_LIBRARY_PATH="$PWD/build/lib" ./build/bin/GSSquared \
    -p 5 -d s6d1=<image.woz> --screenshot 1200 --stop-at-frame 1200 \
    --screenshot-name out
```

`gssquared-bench` is upstream v0.11.0-7 with the two vsim-comparison commits
cherry-picked (branch `bench`). v0.11 matters: it has "IWM / floppy — correct
drive-enable model, empty-drive sense, and LSS clocking".

## First Math Adventures: closed

It was the sequencer, as both primary sources said. Its RWTS re-reads `$C08C`
8 cycles after a D5 and expects the D5 to still be there (`B958-B95E` in the
trace), which only holds if a completed byte stays latched until the *next read
pulse* -- this disk's address marks are D5 plus trailing zero bits. The
read-clears-it gate hid the byte; a fixed 2-cell timer (tried first) is too
short as well. `iwm_flux.v`'s `sr525` path now implements the hold/arm/restart
sequence from OpenEmulator/GSSquared; details and the full before/after table
are in `WOZ_FINDINGS.md`, "Sequencer semantics for 5.25\" sync reads".

The earlier "address vs data prologue asymmetry" was a symptom of the constant
recalibration, not its cause. Don't chase it.

## Bouncing Kamungas: closed (speed, not disk)

It regressed with the sequencer alone and was a CPU-speed bug the shortcut had
been hiding: the game reads a sector at 2.8 MHz during the motor-off second
because our slot-6 slow mode ended at the `$C0E8` access instead of following
the IWM drive enable's one-second holdover. Fixed in `clock_divider.v`; see
`WOZ_FINDINGS.md`, "Bouncing Kamungas". Lesson: a disk that breaks when the
data register starts behaving is not necessarily a disk bug.

## Corpus (202 disks): clean

Diffed against `woz_sp`, not `woz_ref` (which is from 2026-08-28 and predates
four commits): +9 (all Newsroom revisions), and 13 changed of which 7 boot at
2500 frames, 2 are booted programs at a name prompt, and 4 fail identically
on GSSquared `-p 5` (Frogger, Maze Craze, Quadrant 6112, Mr. Do); ROM 01 gives
the same. Details and the Frogger mechanism in `WOZ_FINDINGS.md`, "202-disk
corpus". The reference was re-frozen from this state at 2500 frames (`woz_ref/`).

**Open question, needs real hardware.** Frogger, Maze Craze and Quadrant 6112
booted on the old clear-on-read shortcut and now stop at the IIgs ROM's
"Check startup device!" -- exactly as GSSquared does. If a real ROM 1 or ROM 3
IIgs boots any of them from a 5.25" drive, the sequencer hold is a few
microseconds too short and `sr525_seq_armed` in `iwm_flux.v` is where to look.
If not, this is correct behaviour and they were never really booting.

## Recommended next step

1. Settle the open question above on real hardware before touching the hold.
2. Port the fixed engine to `Apple-II_MiSTer` (its TODO Phase 1 item 4). The
   sequencer maps directly onto the P6; the speed holdover does not apply.
3. Hard Hat Mack / Stargate only if GSSquared can be made to boot them (it
   fails both on `-p 5`, so they are not demonstrably ours).

The window-based 3.5" decoder and latch mode are untouched by the sequencer
change; unifying them would be a real cleanup, but nothing failing motivates it.

## Dead ends — do not repeat

Each was tested and is documented with evidence in `WOZ_FINDINGS.md`.

| Tried | Result |
|-------|--------|
| `BIT_CELL_525` 56 -> 57.2727 | 35 of 202 disks regressed. 56 is calibrated against `ROTATION_CYCLES_14M` |
| weak-bit threshold 7 -> 4 | 12 of 15 disks regressed; the existing Cyclotron comment is right |
| WOZ reference read-head model (one-cell delay, window init 0) | DOS 3.3 itself stops booting |
| removing the `m_data_read` gate | all 26 images drop to TEXT_ONLY |
| data separator, both variants | costs Simultaneous Linear Equations, and does **not** fix First Math |
| re-enabling the stale-data playback gate | no effect |
| even-address data latch (`!ADDR[0]`) | spec-correct, but does not fix it |
| returning live `m_rsh` on post-consume read | no effect |
| TMAP reload caching (P1) | 1 duplicate entry in 66 loads — the defect does not reproduce |
| deferring Q6 reset via `clear_rsh_pending` | breaks Wings of Fury |

## Harness gotchas that cost real time

- **1500 frames minimum.** At 400, Wings of Fury and Hard Hat Mack look like
  failures and are not. At 500, Lode Runner / Karateka / Rescue Raiders too.
- **`--fixed-time` is mandatory** or the RTC is the wall clock and runs are not
  reproducible.
- **The batch harness filters to first-disk/side-A**, dropping 637 images
  including all 11 timing-28 disks. Use `--retest` with an explicit list.
- **Compare against GSSquared on `-p 5` (IIgs)**, not `-p 2`. Platform choice
  flips verdicts both ways — it moved Planetfall and Hard Hat Mack between
  categories. It is blind to CPU-speed bugs (its floppy runs off the CPU
  clock), and it is not frame-comparable for load times.
- **A TIMEOUT cluster is almost always starved workers**, not a regression.
  Check for two suites running at once (`pgrep -x Vemu | wc -l` should be your
  `--jobs` value).
- **PC histograms with CPU tracing above ~200 frames are timeout-truncated** and
  useless for before/after comparison. Use `--no-cpu-log` plus targeted counters.
- **`rtl/flux_drive.v` and `rtl/iwm_flux.v` are CRLF**; most other files are LF.
  Edit with binary-safe IO or you will produce a 4000-line whitespace diff.
- **There are two `FLUX_TRANSITION <= 1'b1` sites** in `flux_drive.v`. The first
  is the FLUX-track path; the bitstream path is the second (~line 1662).
- `pgrep -f <pattern>` matches its own command line. Key monitors on a PID.
  `pkill -f` will kill YOUR shell too.
- **Never edit `run_woztest_suite.sh` while it is running.** bash reads the
  script incrementally; editing it mid-run made it re-execute the job line and
  start a second copy of the suite into the same output directory.
- Rebuilding `obj_dir/` while a suite is running swaps the binary under later
  jobs. Verilate into another `--Mdir` (see `VEMU=` above) instead.
- The corpus harness's 1200 frames is too short now that the motor-off second
  runs at 1 MHz: The Halley Project and seven other corpus disks need up to
  ~2500. Use `--frames 2500` for corpus runs.
- `woz_ref/` is the 2026-09-02 reference at 2500 frames. `woz_ref_20260828/`
  is the old one; `woz_sp/` the last pre-sequencer full run; `woz_out_lss/`
  the post-sequencer run at 1200 frames.

## Corrections I made to my own earlier conclusions

Listed because they are in the git history and could mislead:

- I reverted `optimal_bit_timing` (`051cd6c`) on reasoning that assumed a fixed
  200 ms revolution. These disks deliberately violate that. Restored in `d3ab554`.
- I called Planetfall, Apple IIgs System Disk and Crystal Quest "our bugs". All
  three were **booting**; the PNG-size classifier mis-scored them.
- I called Hard Hat Mack "our bug" from an IIe run. On IIgs a known-good
  emulator fails it identically.
- I wrote that the IWM never saw the flux edges at the failing cells. It does.
