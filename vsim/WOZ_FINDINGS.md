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

## P0a -- bit cell timing: PARTLY REAL (corrected)

Two separate claims here; the first is wrong and the second is right.

**Raising BIT_CELL_525 from 56 to 57.2727 is wrong.** It regressed **35 of 202
disks with 0 improvements**. The constant is calibrated against
`ROTATION_CYCLES_14M`, not derived from microseconds: the corpus median track
holds 50,985 bits, which against the 200 ms rotation constant implies 56.17
cycles/bit. Real drives run nearer 294 RPM than 300, so Applesauce captures
~51k bits/track rather than the theoretical 50k. The two constants are a
matched pair; raising one alone makes the disk stream ~2% slow against its own
data.

Note also that `iwm_flux.v` carries its **own** copy of the cell constant
(`SR525_BIT_CELL`, `base_full_window`). Drive and IWM are both "wrong" by the
same amount and therefore stay in lockstep; changing either alone desynchronises
them within a few dozen bits.

**Honouring INFO byte 39 (`optimal_bit_timing`) is right**, and is implemented in
`dc4daf6` as a ratio against the calibrated constant
(`cell = BIT_CELL_525 * timing / 32 = timing * 7/4`), so timing 32 yields exactly
56 and the 2,572 standard disks are bit-identical by construction.

I briefly reverted that in `051cd6c` after observing that the 22 non-standard
disks hold ~50k bits/track like everything else, concluding their implied cell
stays near 56. **That reasoning was wrong** and the revert was undone in
`d3ab554`. It assumed every disk takes exactly 200 ms per revolution, and these
are precisely the disks that do not. From `WozTestImages/readme.txt`:

    They would slow down or speed up the drives before writing them just to
    mess with bit copiers [...] "Border Zone" [...] has a very timing dependent
    disk reader that will tend to lose sync with the disk if the bits are coming
    in at 4 microseconds [...] Using a 4 microsecond bit timing, this little test
    can run almost a minute and a half. If you use the 3.5 microsecond timing as
    indicated in the WOZ file, then the test tends to take around 17 seconds.

A disk written on a deliberately fast drive holds a normal bit count that must be
clocked out faster, so ~50k bits is expected rather than evidence against
scaling. The official Border Zone test image matches our corpus copy (50,346
bits at timing 28).

That quote also explains why the 202-disk verification showed 0 improvements and
0 regressions, which I first misread as the fix being inert: honouring the timing
changes how fast a timing-sensitive reader syncs, not whether the disk boots.
**A boot-screenshot harness cannot measure this fix at all.** Border Zone's
stopwatch test (90 s versus 17 s to reach the `>` prompt) is the real check and
needs scripted keystrokes across a disk swap.

The 22 disks still do not boot, but that is a separate matter: the 11 timing-28
images are Infocom **side B data disks**, and "Check startup device!" is the
correct response to a volume with no boot block. Only ~12 of the 22 are
boot-testable at all.

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

---

# WOZ Test Images benchmark

`vsim/WozTestImages/` holds John K. Morris's official WOZ Test Images (v1.4,
2021). Each image isolates one floppy behaviour and `readme.txt` states the
expected outcome, so a failure is a named diagnosis rather than "did not boot".
Morris: *"They are all verified as good images. You can trust them. If they
don't work for some reason, then it is something about your implementation."*

Run with `./run_woztest_suite.sh [outdir] [frames] [jobs]` (1500 frames is
enough; 400 is not).

## Our score: 13 of 26

**Passing** — DOS 3.3 System Master, The Apple at Play, Bouncing Kamungas,
Rescue Raiders, Sammy Lightfoot, Dino Eggs, Crisis Mountain, Miner 2049er II,
Blazing Paddles, Take 1, The Bilestoad, The Print Shop Companion,
Stickybear Town Builder.

Several of those are the hard cases: Blazing Paddles and Take 1 are the
cross-track synchronisation tests, The Bilestoad is half-track addressing, and
**The Print Shop Companion is the MC3470 fake-bit test** -- which independently
validates leaving the weak-bit threshold at 7. The TODO's proposed 7->4 change
would have broken the very disk that certifies weak-bit handling.

## Confirmed our bugs (GSSquared v0.11 boots them, we do not)

| Disk | What the readme says it tests |
|------|-------------------------------|
| Commando | basic copy protection |
| Wings of Fury | offset data streams (mid-nibble latch reset via `LDA $C08D,x`) |
| Hard Hat Mack | extra-wide track (2 tracks wide) |
| First Math Adventures | data-latch lifespan: a read must NOT clear the latch |

Note Wings of Fury and Stickybear Town Builder test the *same* behaviour and we
pass one and fail the other -- a tight pair for isolating the bug.

## Not reproduced as our bugs

GSSquared also fails Stargate, Planetfall, Border Zone side A, DOS 3.2 System
Master (13-sector, explicitly optional) and the WOZ 2.1 ProDOS FLUX image under
`-p 2`. Treat the last two as provisional: platform choice may be wrong.

## Lead: the data latch is cleared on read

`iwm_flux.v` gates the latch on `m_data_read`:

    wire data_ready = m_data[7] && (!m_data_read || smartport_mode_local);
    wire [7:0] effective_data = data_ready ? m_data : 8'h00;

so a second read of the same byte returns 00. Real hardware holds the byte until
the next one shifts in; bit 7 clears because the shift register restarts, not
because the CPU read it. That is exactly what First Math Adventures checks.

The gate is load-bearing -- its comment says it "prevents duplicate reads in the
ROM's BPL polling loop that broke D5 AA 96 prologues" -- so removing it needs the
correct LSS behaviour (clear bit 7 when a new byte starts accumulating) rather
than a straight deletion. Verify against First Math Adventures and Wings of Fury,
and re-check the whole 26-image suite for prologue regressions.

## Benchmarking against GSSquared

`/home/alans/mister/gssquared-bench` is upstream v0.11.0-7 with the two
vsim-comparison commits from `alanswx/gssquared` cherry-picked on top (branch
`bench`). v0.11 matters: it carries "IWM / floppy -- correct drive-enable model,
empty-drive sense, and LSS clocking", which post-dates the local fork.

    cd /home/alans/mister/gssquared-bench
    cmake --install build          # REQUIRED: build/GSSquared aborts on a missing font
    DISPLAY=:0 LD_LIBRARY_PATH="$PWD/build/lib" ./build/bin/GSSquared \
        -p 2 -d s6d1=<image.woz> --screenshot 1200 --stop-at-frame 1200 \
        --screenshot-name out

Platforms: 0=II, 1=II+, 2=IIe, 3=IIe Enh, 4=IIe 65816, 5=IIgs. Compare screens
visually -- PNG byte size differs between the two emulators and is only a rough
proxy within one of them.
