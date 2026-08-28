# WOZ engine: measured findings

Results of working through the six WOZ defects listed in
`Apple-II_MiSTer/TODO.md` (Phase 1, item 4) against the 2,860-image
`vsim/disks_525/` corpus. Three of the six turned out to be misdiagnosed.
Everything below is measured, not inferred; the tooling to reproduce it is in
this directory.

## Tooling

| File | Purpose |
|------|---------|
| `test_woz_batch.sh` | Batch harness (pre-existing; now passes `--fixed-time`) |
| `woz_defect_map.csv` | Per-disk defect classification, 2,860 rows |
| `woz_join.py` | Joins a results.csv against the defect map -> per-defect boot rates |
| `woz_compare.py` | Diffs two results.csv files, ranked by status |
| `woz_p1_baseline.sh` | Counts track loads vs physical track changes per boot |

Reference run at HEAD (202 disks: 22 non-standard-timing + 180 controls):
`BOOTED=180 TEXT_ONLY=22 BLANK=0 TIMEOUT=0`. Full-corpus baseline (1,606
disks) boots 48.0%.

## Harness caveats that cost real time

- **Stock defaults cannot produce a usable report.** 1000 frames at ~0.257
  s/frame is ~257 s of work against a 300 s default timeout; under 15-way
  parallelism the first 28-disk sample returned 28/28 TIMEOUT.
- **500 frames manufactures false failures.** Lode Runner, Karateka and
  Rescue Raiders all read BLANK at 500 frames and BOOT at 1200.
- **The first-disk/side-A filter hides evidence.** It drops 637 images,
  including all 11 timing-28 disks -- the entire diagnostic set for the
  bit-cell work. Use `--retest` with an explicit list.
- **`--fixed-time` is mandatory.** Without it the RTC is the wall clock and
  results are not reproducible: "Dinosaur Days Plus disk 2A" reported
  TEXT_ONLY in a batch and BOOTED standalone. Fixed in `72e17ea`.
- **Treat any TIMEOUT cluster as suspect.** A contiguous alphabetical block of
  15 timeouts turned out to be one starved wave of workers, not a regression.

## P0a -- bit cell timing: NOT A DEFECT

The TODO says `BIT_CELL_525 = 56` is wrong because 4 us at 14.318181 MHz is
57.2727 cycles, a "2.27% systematic error on every disk". Both the literal fix
and a scaled variant were tried and both are wrong.

- Raising the cell to 57.2727 regressed **35 of 202 disks, 0 improvements**.
- `BIT_CELL_525` is calibrated against `ROTATION_CYCLES_14M`, not derived from
  microseconds. The corpus median track holds **50,985 bits**, which against
  the 200 ms rotation constant implies **56.17 cycles/bit**. Real drives run
  nearer 294 RPM than 300, so Applesauce captures ~51k bits/track, not the
  theoretical 50k. The two constants are a matched pair.
- Scaling the cell by INFO byte 39 (`optimal_bit_timing`) is also wrong. The 22
  non-standard-timing disks hold 49.9k-53.4k bits/track -- the *same* range as
  ordinary disks -- so their implied cell stays near 56 throughout. Plain 56 is
  closer than the scaled value for **22 of 22 disks, zero exceptions**. That
  work was committed as `dc4daf6` and reverted in `051cd6c`.

Also note `iwm_flux.v` carries its **own** copy of the cell constant
(`SR525_BIT_CELL`, `base_full_window`). Drive and IWM are both "wrong" by the
same amount and therefore stay in lockstep; changing either alone desynchronises
them within a few dozen bits.

The 22 disks do not boot, but that is not a timing fault. The 11 timing-28
images are Infocom **side B data disks** -- "Check startup device!" is the
correct response to a volume with no boot block, so booting them was never a
valid test. Only ~12 of the 22 are boot-testable at all.

## P0b -- data separator: REAL, PARKED

Confirmed in source, and the code documents it: drive and IWM timers both
free-run and never re-phase, so a boot can settle into a phase where every flux
edge lands on a shift cycle and zeros shift forever. `iwm_flux.v` calls this a
"HW-only LR black-screen wedge; sim phases never align"; `iwm_woz.v` notes
hardware "went 0/5" with the playback gate enabled.

Two variants on branch `woz-separator-wip`; both cost the same disk
(Simultaneous Linear Equations, BOOTED -> BLANK) with 0 improvements. Parked
because **the simulator structurally cannot show this working** -- the wedge
only manifests when hardware phases align. Needs FPGA testing.

## P1 -- TMAP redundant reloads: NOT REPRODUCIBLE

The claim is that a quarter-track nudge resolving to the same TRKS entry still
re-reads 13 identical blocks. Instrumenting the TMAP resolution shows this
essentially does not happen: across Lode Runner, Gumball, Karateka, Choplifter
and Frogger, **1 consecutive duplicate entry in 66 loads**.

Lode Runner's half-track protection alternates track 52 -> entry 11 and track
54 -> entry 13. Those are genuinely *different* tracks, so each reload is
correct. With a single track buffer, alternation requires reloading; that is
inherent to the design, not a bug. A one-deep cache never hits.

Caveat: measured over boot only (300-350 frames). Gameplay head movement was
not tested and cannot be driven from this harness.

Beware the obvious metric. "Track loads minus physical track changes" runs
36-55% on *every* disk including whole-track controls (Airheart 41%, Addition
Magician 55%), so it does not measure TMAP aliasing at all.

What may be real is the separate observation that the stale-data gate is
disabled (`iwm_woz.v:762`), so the drive streams mixed old/new BRAM *during*
a legitimate reload. That is a different bug from TMAP caching.

## P2 -- weak bits: PARTLY REAL

Three sub-claims; one holds.

- **Threshold 7 -> 4: wrong.** Regressed **12 of 15 disks** -- Cyclotron,
  Gumball, Karateka, Lode Runner, Alcazar, Airheart, Frogger, Choplifter and
  more. The pre-existing comment warning that a low threshold "corrupts
  legitimate gap data ... notably the Cyclotron WOZ-a-Day capture whose track 0
  begins with a 4-bit zero run" is correct.
- **One-cell delay (`read_buffer & 0x2`): not viable as-is.** `head_window` is
  reset to `4'hF` on track load and wrap and is not updated on every cell
  (write-strobe steal, BRAM wait), so feeding it to the output desynchronises
  the bitstream from `bit_position`. Adding it did not rescue threshold 4.
- **Free-running LFSR: real, fixed** in `a530e43`. Noise now advances only on
  fake-bit consumption, mirroring `clem_drive.c`'s `random_bit_index`.
  Do **not** reseed it at track wrap -- that makes every revolution produce
  identical noise, defeating the point of weak bits, and cost 3 disks.

## P3 -- write-back corruption: REAL, FIXED

Confirmed in source. `trk_start_block_sideN` / `trk_block_count_sideN` are
assigned only on the successful-load path; the empty-TMAP path updates
`current_track_id_sideN` and clears dirty but leaves those pointers aimed at the
*previous* track, while `bit_we` set dirty unconditionally. Writing an unmapped
track flushed BRAM over whichever track was last loaded.

Fixed in `a530e43`. Still wants a write-then-verify test -- a boot run can only
show it does no harm. The sim does persist writes (`sim_blkdevice.cpp`
`disk[i].put()` / `flush()`), so before/after image checksums are a workable
approach.

## P4 -- angular position: NOT ATTEMPTED

Needs `new_pos = old_pos * new_count / old_count` (a divide) or a restructure of
`bit_position` into fractional form. The P4 bucket boots *above* control (53.6%
vs 48.2%), so the corpus cannot score it either way. Deferred rather than
committed unverified.

## What the corpus can and cannot measure

Only P0a and P2's threshold have boot-level signal. P1, P3 and P4 all sit at or
above the control boot rate, because they do not manifest during a boot --
nothing writes, seek glitches show up in gameplay, and track-arc timing is
invisible to a screenshot. Using the corpus as their pass criterion produces a
flat line whether a fix works or not, which reads as "no regression" and is
worse than no test.
