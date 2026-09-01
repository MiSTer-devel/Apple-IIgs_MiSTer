# WOZ work — handoff

State as of 2026-09-01. Branch `woz-fixes`, 25 commits ahead of `main`, tree clean.
Read this first, then `WOZ_FINDINGS.md` for the evidence behind every claim.

## TL;DR

Started from the six WOZ defects in `Apple-II_MiSTer/TODO.md` (Phase 1, item 4).
**Three of the six were misdiagnosed.** Four RTL fixes shipped. One bug remains
open with a full diagnosis. The durable output is the measurement setup: a
verified-good test suite, a known-good reference emulator, and ~15 documented
dead ends.

WOZ Test Images score: **19 of 26 BOOTED.**

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

`458dd35` carries one known regression: **The Halley Project** goes BOOTED ->
BLANK in the corpus. Taken deliberately; reasoning is in that commit message.

## Tooling — exact commands

```bash
cd vsim

# WOZ Test Images (26 verified-good images, each isolating one behaviour)
./run_woztest_suite.sh woztest_out 1500 12      # 1500 frames; 400 is NOT enough

# 202-disk corpus regression (22 odd-timing + 180 controls)
./test_woz_batch.sh --retest verify_p0.txt --jobs 12 --frames 1200 \
                    --timeout 1400 --out woz_out
python3 woz_compare.py woz_out/results.csv woz_ref/results.csv

# per-defect boot rates against the classification map
python3 woz_join.py woz_out/results.csv

# reference emulator (known-good). MUST use -p 5 (IIgs) to match our core.
cd /home/alans/mister/gssquared-bench
cmake --install build            # REQUIRED; build/GSSquared aborts on a missing font
DISPLAY=:0 LD_LIBRARY_PATH="$PWD/build/lib" ./build/bin/GSSquared \
    -p 5 -d s6d1=<image.woz> --screenshot 1200 --stop-at-frame 1200 \
    --screenshot-name out
```

`gssquared-bench` is upstream v0.11.0-7 with the two vsim-comparison commits
cherry-picked (branch `bench`). v0.11 matters: it has "IWM / floppy — correct
drive-enable model, empty-drive sense, and LSS clocking".

## The one open bug: First Math Adventures

GSSquared boots it on `-p 5`; we stop at the ROM splash. It is the WOZ suite's
data-latch-lifespan test.

**Symptom.** Stuck in the DOS 3.3 RWTS (`$B900-$BAFF`) prologue search:
`CMP #$D5 / BNE` runs 63k times, ~1640 get past it. 118 seeks over 400 frames,
oscillating between quarter-track 0 and the unmapped quarter-track 2.

**Measured.** Prologue counts `addr=229 data=334` where DOS 3.3 is a balanced
`345/343`. The asymmetry tracks sync length: this disk's **address** fields
carry ~4 self-sync bytes, its **data** fields 7-8, and we miss the short-sync
ones. So byte framing is lost routinely and only recovers when a long enough
sync run follows. DOS 3.3 has 16 sync bytes before every address field, which is
why it is immune.

**Verified correct end to end for a single cell** (this is the useful part —
don't re-check these):
- WOZ data is right (`addr=19 data=96`)
- drive asserts flux for both adjacent 1-bits
- every assertion is a clean 1-cycle pulse (`flux_high_cycles == rising_edges`, 690692 each)
- `flux_edge` fires
- the two cell counters are in **fixed phase**, constant 19-clock offset, no drift

So the remaining fault is **recurring framing loss across field boundaries**,
not within a cell.

## Recommended next step

Implement the real **LSS (logic state sequencer)** rather than patching the
simplified shift register. Both primary sources point there:

- WOZ 2 reference: <https://applesaucefdc.com/woz/reference2/>
- `gssquared-bench/Docs/Woz.md` — Bazyar's dev log. He hit this exact disk with
  this exact symptom ("then it tries to read, then it does a recalibrate") and
  ended up implementing the real LSS. Read "Thinking about the LSS" onward.

Our `sr525` path is a simplified shift register; a comment there records that a
window-based decoder was tried and abandoned because it "breaks timing-sensitive
copy protection". That is a refactor with real regression risk across all 26
images — scope it deliberately.

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
  categories.
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

## Corrections I made to my own earlier conclusions

Listed because they are in the git history and could mislead:

- I reverted `optimal_bit_timing` (`051cd6c`) on reasoning that assumed a fixed
  200 ms revolution. These disks deliberately violate that. Restored in `d3ab554`.
- I called Planetfall, Apple IIgs System Disk and Crystal Quest "our bugs". All
  three were **booting**; the PNG-size classifier mis-scored them.
- I called Hard Hat Mack "our bug" from an IIe run. On IIgs a known-good
  emulator fails it identically.
- I wrote that the IWM never saw the flux edges at the failing cells. It does.
