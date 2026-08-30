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

## Final classification -- every image checked against GSSquared on IIgs

**Run the reference on `-p 5` (IIgs), not `-p 2` (IIe).** Our core is a IIgs and
several of these are Apple II-era disks; comparing against IIe misclassifies
disks that simply do not run on a IIgs as our bugs. Platform choice flips
verdicts in both directions. Control: DOS 3.3 System Master boots on `-p 5`
(2777 bytes), so the platform itself is fine.

Score after fixing the result classifier: **19 of 26 BOOTED.**

| Disk | GSSquared IIgs | Us | Verdict |
|------|----------------|-----|---------|
| Commando | boots | boots | **FIXED** `458dd35` |
| Wings of Fury A | boots | boots | **FIXED** `458dd35` |
| First Math Adventures | boots ("Do you want sound?") | ROM splash | **OURS -- the one real bug left** |
| Planetfall | boots | boots | was never broken; classifier artifact |
| Apple IIgs System Disk 1.1 | -- | boots (ProDOS 16 loader) | classifier artifact |
| Crystal Quest | -- | boots ("Welcome to the IIgs") | classifier artifact |
| Hard Hat Mack | fails, "Check startup device!" | same | not ours |
| Stargate | fails | fails | not ours |
| Border Zone A | fails | fails | not ours |
| ProDOS User's Disk (FLUX) | fails, "Check startup device!" | same | not ours on this platform |
| DOS 3.2 System Master | garbage even on `-p 0` | fails | 13-sector, explicitly optional |
| Wings of Fury B | -- | "Check startup device!" | data side; correct behaviour |

So **one** confirmed defect remains, not the five-item backlog earlier drafts of
this document listed.

### FLUX (WOZ 2.1) parses and loads correctly

Worth recording because it looked like a feature gap. Tracing the ProDOS image:

    WOZ_SCAN: INFO v3 flux_block=1360
    WOZ_CTRL: Track 0 has FLUX data at TRKS entry 17
    WOZ_CTRL: FLUX Track Info: StartBlock=224 BlockCount=61 FluxBytes=30908
    WOZ_CTRL: Stored track 0 to side0 RAM, flux_bytes=30908 is_flux=1
    WOZ_CTRL: Flux ticks sum=1605290

The tick sum is right: 1,605,290 x 125 ns = 200.7 ms, one revolution at ~299 RPM.
Parsing, chunk seeking, per-track flux/bitstream selection and loading all work.
The disk then performs exactly one seek (to track 0) and stops, so if there is a
flux defect it is in playback, not in the chunk handling. But GSSquared fails
this image on IIgs the same way, so it is not demonstrably ours.

### Q6H reset ($C08D) -- fixed, with one known regression

`458dd35` adds the missing Q6 rising-edge reset of the read shift register.
Suite 13 -> 15. Costs "The Halley Project" (BOOTED -> BLANK) in the corpus.

Three refinements failed to recover it: gating on read mode (`!SW_Q7`),
preserving the pending flux edge, and both. Both Halley Project and Wings of
Fury fire **exactly 3 Q6 resets over 400 frames**, so the trigger is not
over-firing; the remaining error is *where in the bit cell* the reset lands.
That is the thread to pull next, and it needs LSS cycle analysis rather than
more experiments.

### Hard Hat Mack: not a floppy bug (see table above)

Quarter-track -> TRKS entry, first twelve tracks:

    DOS 3.3 (normal):      T  T  --  T+1     half-track slot is 0xFF
    Hard Hat Mack (wide):  T  T   T  T+1     half-track slot maps to T

Each entry claims 4 quarter-positions instead of 3. This *should* already work
-- the lookup is just `TMAP[quarter]`, and the -2 quarter-track offset in
`Apple-IIgs.sv` still lands a half-track head on `4T+2` -> entry `T`. So the
failure is somewhere other than the TMAP lookup.

Note Wings of Fury and Stickybear Town Builder test the *same* behaviour and we
pass one and fail the other -- a tight pair for isolating the bug.

## Not reproduced as our bugs

GSSquared also fails Stargate, Border Zone side A, DOS 3.2 System Master
(13-sector, explicitly optional; it shows garbage even on `-p 0`) and the WOZ 2.1
ProDOS FLUX image.

Treat "not confirmed" as provisional, not exonerating: **platform choice
changes the verdict.** Planetfall looked like a shared failure on `-p 2` (IIe)
and boots cleanly on `-p 1` (II+), which moved it into the confirmed-ours list.
Stargate and the FLUX image may do the same under a configuration not yet tried.

## Lead: the data latch is cleared on read

`iwm_flux.v` gates the latch on `m_data_read`:

    wire data_ready = m_data[7] && (!m_data_read || smartport_mode_local);
    wire [7:0] effective_data = data_ready ? m_data : 8'h00;

so a second read of the same byte returns 00. Real hardware holds the byte until
the next one shifts in; bit 7 clears because the shift register restarts, not
because the CPU read it. That is exactly what First Math Adventures checks.

The gate is load-bearing. **Tested: removing it outright breaks everything.**
With `data_ready = m_data[7]`, all 26 test images drop to TEXT_ONLY -- including
DOS 3.3 System Master, the simplest disk in the set. Nothing boots at all. (Three
images move BLANK -> TEXT_ONLY, but that is not an improvement: it just means they
now fail at the ROM splash instead of failing later.) The comment on the gate,
"prevents duplicate reads in the ROM's BPL polling loop that broke D5 AA 96
prologues", is exactly right.

So the fix is not a deletion. Real hardware holds a completed byte only briefly:
the LSS sits in hold states for roughly two bit-times, then clears and resumes
accumulating, so bit 7 falls on its own without the CPU having read anything.
Our `latch_hold_cnt` models a hold (8 bit-times, mode bit 0) but line ~1921
cancels it on read, and `m_data_read` then zeroes the value.

A correct fix has to make bit 7 fall on a *timer*, not on a read -- while still
falling fast enough that the ROM's polling loop (roughly 2.5-5 bit-times between
reads at 1 MHz) cannot see the same byte twice. That window is tight and is
probably why the read-clears shortcut was taken.

**Measured, and it rules out the simple story.** Counting data-register reads
suppressed to 00 purely because the byte was already read:

    First Math Adventures   suppressed=111616  served=52730   ratio 2.12
    DOS 3.3 System Master   suppressed= 80896  served=44171   ratio 1.83

DOS 3.3 boots and First Math does not, yet both suppress at a similar rate. The
counter is dominated by ordinary ROM polling (the BPL loop re-reading while it
waits), not by a program deliberately re-reading a byte. So "First Math hits the
clear-on-read shortcut unusually often" is **not** the explanation, and a fix
aimed at that alone is unlikely to help.

Next step for this one is a CPU trace diff rather than more RTL probing.
GSSquared boots it on `-p 5` and can dump a 65816 trace (`--trace-entries`,
decoded with `build/gstrace`); `COMPARING_WITH_VSIM.md` documents the workflow,
and `compare_traces.py` exists for the diff. Find where the two diverge and work
back from there.

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


---

## First Math Adventures -- the remaining bug, characterised

GSSquared boots it on `-p 5`; we stall. What is known:

**It is a failing-read retry loop.** 276 seeks over 600 frames, across only 9
distinct tracks, ending in a tight oscillation between quarter-track 0 and
quarter-track 2 (119 and 121 visits). Quarter 2 is `0xFF` in TMAP -- unmapped --
so half the retry loop is reading synthesised noise off an empty track.

**Prologue detection is lopsided.** Counting `D5 AA 96` / `D5 AA AD` sequences
out of the 5.25" shift register over 400 frames:

    DOS 3.3 System Master   addr=344  data=344     balanced, boots
    Commando                addr=344  data=341     balanced, boots
    First Math Adventures   addr=228  data=333     lopsided, fails

Careful: this is partly an *effect* of the retry loop, since the empty-track
half of the oscillation contributes bytes but almost no prologues. It is not
proof of an address-field decode fault on its own.

**Why this disk is sensitive.** Its address fields are preceded by only about
four 10-bit self-sync bytes, where DOS 3.3 has sixteen. Measured as bit-gaps
between framed bytes on track 0:

    ...
    387  DF   bit-gap=10     <- self-sync (10-bit cells)
    390  D5   bit-gap=10
    391  DB   bit-gap= 8     <- normal bytes resume
    401  96   bit-gap= 8     <- D5 AA 96
    ...

A short sync run leaves very little margin to re-frame, so any dropped or
duplicated bit in the read path persists instead of being corrected at the next
gap. That is what "lifespan of the data latch" is really probing.

(An earlier draft of this section claimed the disk had *no* sync bytes at all.
That was an artefact of a naive Python framer entering the region mis-framed and
decoding the sync bytes as DF/BB/FB rather than FF.)

### Ruled out

- **Not the Q6H reset** added in `458dd35`: both First Math and DOS 3.3 trigger
  exactly 2 Q6 resets per boot.
- **Not the clear-on-read shortcut alone**: suppressed-read rates are comparable
  between First Math (2.12 suppressed per served) and DOS 3.3 (1.83), which
  boots.
- **Not a double clear of `m_rsh`.** The sync-mode path clears the register
  immediately *and* arms `clear_rsh_pending`, which fires a cycle later. That
  looked like it could drop a bit and slip framing permanently on a
  short-sync disk, but removing the redundant arm changed the prologue counts
  not at all (228/333 before and after). Reverted as inert. Still arguably worth
  tidying, but it is not this bug.

### Next

Trace diff. GSSquared boots it on `-p 5` and dumps a 65816 trace
(`--trace-entries`, decode with `build/gstrace`); `COMPARING_WITH_VSIM.md` and
`compare_traces.py` describe the workflow. Diverge-point analysis will say
whether the RWTS gives up on a bad checksum, a missing address field, or a
timeout -- which the black-box measurements above cannot separate.
