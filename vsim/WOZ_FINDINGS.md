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

### Where execution actually is

PC distribution over a 400-frame run here, by bank:page:

    799370  FF:FC     ROM
    686077  00:B9     <- DOS 3.3 RWTS
    505412  00:BA     <- DOS 3.3 RWTS
    195827  FC:CE     ROM
    167590  00:C6

We are stuck in the **DOS 3.3 RWTS** ($B900-$BAFF), the sector read/retry code,
burning over a million instructions there and never leaving.

GSSquared on the same disk finishes the read early -- by frame ~30 -- and runs
the program's own code in page `00:64xx`, ending at a keyboard poll
(`6455: LDA $C000 / BPL $6455`), which is the "Do you want sound? Y/N" prompt.
So the divergence is unambiguous: their RWTS returns a good sector and ours
never does.

### Next

Instruction-level diff inside the RWTS. Two practical notes learned the hard way:

- **GSSquared's trace ring holds ~100k instructions regardless of what
  `--trace-entries` asks for** -- about 6 frames at 1 MHz. Asking for 2,000,000
  still yields 100,000. To catch the disk read you must stop the run *during*
  it; by frame 40 the read is already over and the ring only shows the keyboard
  loop.
- Our CPU log is `bank:PC: mnemonic` on stdout (no flag needed; `--no-cpu-log`
  suppresses it), so `grep -oE '^[0-9A-F]{2}:[0-9A-F]{2}'` gives a cheap PC
  histogram without the 200 MB/100-frame CSV trace.

The specific question to answer: inside $B900-$BAFF, does the RWTS fail on the
address-field checksum, the data-field checksum, or a sector-not-found timeout?
That distinguishes a framing fault from a data fault, which none of the
black-box measurements here could separate.


## First Math -- byte-level diagnosis (still unfixed)

Dumping the bytes the 5.25" shift register produces and anchoring them against a
Python decode of the same WOZ track gives an exact miscompare:

    WOZ track data:  DF BB FB D5 DB AF EB FE AA FF AB BF D5 AA 96
    our RTL output:  DF BB FB D5 DB AF EB FE AA FF AB BF D5 AA 90
                                                             ^^^^

Fourteen bytes match exactly, then the **third byte of the address prologue is
read as 0x90 instead of 0x96**:

    96 = 1001 0110
    90 = 1001 0000      two 1-bits lost

That single byte is why the RWTS never matches a prologue: the histogram shows
`B954/B956` (`CMP #$D5 / BNE`) executing 63k times and only ~1640 reaching the
byte after it.

The 0x96 cell pattern is unremarkable -- 8 normal cells, `10010110`, no long
zero run, no self-sync, no 10-bit cell. The preceding `D5` (`11010101`) also has
adjacent 1-bits and decodes correctly, so back-to-back flux transitions are not
inherently broken.

**Not a whole-bit framing shift.** Re-framing the WOZ stream at every bit offset
from -3 to +5 around that byte fails to re-align it with our subsequent output
(best 1/20 bytes). Caveat on that test: the RTL dump is from a live boot, so the
drive seeks after this point and the later bytes are not expected to correspond
to this track anyway. The 14-byte match before the miscompare is the solid part.

### Eliminated for this bug

- Q6H reset (`458dd35`) -- both this disk and DOS 3.3 fire exactly 2 resets
- clear-on-read shortcut -- suppression rates comparable to a disk that boots
- double clear of `m_rsh` in the sync-mode path -- removing it changed nothing
- data separator, **both** variants from `woz-separator-wip` -- still 0x90
- weak-bit injection -- disabling it entirely leaves the byte stream
  *byte-identical*, so it is not touching this region

### Where to pick up

The question is now very narrow: why do two 1-bits inside one ordinary 8-cell
byte read as 0, when the neighbouring bytes decode correctly? That is a
cell-sampling question in `iwm_flux.v`'s `sr525` path or in `flux_drive.v`'s
transition generation, and it should be reproducible in a short VCD capture
around that byte rather than by booting the disk. `--dump-vcd-after` with a
2-3 frame window is the tool; the byte is reached early in the first track-0
read.


## What the primary docs say (WOZ 2 reference + GSSquared dev log)

Read late -- these should be consulted before any further IWM work.
Sources: <https://applesaucefdc.com/woz/reference2/> and
`gssquared/Docs/Woz.md` (Jawaid Bazyar's dev log, which walks through getting
each of these same test images to boot).

**1. `$C08D` resets the sequencer and clears the data latch.** Quoted directly:
*"reading $C08D,X will reset the sequencer and clear the contents of the data
latch"*, used by E7 and similar protection to resynchronise the nibble stream.
This independently confirms the Q6H fix in `458dd35` -- it is spec behaviour,
not a guess.

**2. Every EVEN soft switch returns the data latch.** *"the low bit of the
address line (A0) is connected through a NOT gate to the Output Enable line of
the data latch. Therefore every soft switch on an even address should actually
return the value of the data latch."* We gate `rd_is_data_reg` on `ADDR[3]`,
restricting the latch to `$C088-$C08F`. Implementing `!ADDR[0]` instead is
closer to the hardware; tried, and it does **not** fix First Math on its own, so
it was reverted rather than shipped unverified. Worth revisiting as a separate
correctness change with a full suite run behind it.

**3. The reference fake-bit algorithm, verbatim:**

    uint8_t head_window = 0;
    uint8_t nextDiskBit() {
        head_window <<= 1;
        head_window |= getNextWozBit();
        if ((head_window & 0x0f) != 0x00) {
            return (head_window & 0x02) >> 1;
        } else {
            return fakeBit();
        }
    }

with *"a randomly-filled circular buffer of 32 bytes"* and *"roughly 30% of the
buffer be 1 bits"* (our LFSR gate is `< 4'd5` of 16, i.e. 31% -- correct).
Note `(head_window & 0x02) >> 1` is the **one-cell delay**, and the zero-run
threshold is **4**, not 7.

**Tested properly and it does not work here.** A first attempt regressed 12 of
15 disks, which I attributed to `head_window` being reset to `4'hF` rather than
0. Re-implemented faithfully -- window initialised to `4'h0` at reset, track
load and wrap; window test `{head_window[2:0], current_bit} == 0`; output the
one-cell-delayed `head_window[0]` -- and **DOS 3.3 System Master itself stops
booting** ("Check startup device!", 5615 bytes). So the init value was not the
problem: the one-cell delay is incompatible with something else in this drive's
data path, and the reference algorithm cannot simply be dropped in.

The likely reason is architectural. The reference describes what the read head
presents to the controller in an emulator where one component walks the
bitstream. Here `flux_drive` emits a flux transition per 1-bit at mid-cell and
`iwm_flux` re-derives bits from those transitions, with `bit_position`,
`TRACK_LOAD_COMPLETE` and the wrap logic all keyed to the undelayed stream.
Introducing a one-cell delay in the drive alone desynchronises it from
everything downstream. Landing the reference model would mean moving the
head-window into the decode side, or delaying the position bookkeeping with it
-- a real refactor, not a patch.

**4. Bazyar hit the identical First Math failure** and logged the fix:
*"I think read should clear the data register ONLY when the hi bit is set (i.e.
QA) [...] after the 'should not clear latch', First Math works!!"* Our
`rd_ack_take` already requires `rd_data_latched[7]`, so we match that rule.
Returning the live `m_rsh` instead of `8'h00` on a post-consume read (closer to
a real LSS, which keeps accumulating rather than parking at zero) was also
tried: no change. Both reverted.

His log is worth reading in full -- it also records that Print Shop Companion
needed random bits in long zero runs (*"inserting random bits when the source
has long runs of 0's makes it BOOT!!!"*), which we already do and pass.


## First Math -- cell-level trace (the sharpest picture so far)

Logging every bit cell the 5.25" shift register consumes, armed on each `D5 AA`,
gives a clean signature. Only the **first** address prologue on the track is
corrupted; every later one decodes correctly:

    pos=160    1 0 0 1 0 0 0 0  -> 90    WRONG  (first sector after playback starts)
    pos=3245   1 0 0 1 0 1 1 0  -> 96    correct
    pos=6330   ...              -> 96    correct
    pos=9415 / 12500 / 15585 / 18670     all correct

The 3085-bit spacing is one sector, so these are consecutive sectors on the same
track and the bit pattern being decoded is identical each time. The failure is
therefore **positional, not data-dependent**.

At the corruption the flux stops outright: cells 158-164 all read 0 with
`rdy=1 spin=1`, i.e. the drive is nominally ready and spinning but emits no
transitions for about seven cells. Two 1-bits inside the `96` fall in that hole.

Control: DOS 3.3 System Master's first `D5 AA` is followed by a correctly
decoded `AD`, so a corrupt first sector is *not* normal startup behaviour here.

Why it is fatal for this disk specifically: its address fields carry only ~4
self-sync bytes where DOS 3.3 has 16, so there is not enough sync to re-frame
after the hole. It then re-seeks, which reloads the track, which reproduces the
hole -- the 0<->2 oscillation.

### Also eliminated

- **Re-enabling the stale-data playback gate** (`iwm_woz.v`, `drive525_track_loaded
  = DISK_READY[0] && WOZ_TRACK1_DATA_VALID`). The flux hole looks exactly like a
  read crossing a track reload, which is what that gate exists to prevent, but
  enabling it does not fix the disk. Reverted.
- **Even-address data latch** (`!ADDR[0]` instead of `ADDR[3]`) -- spec-correct
  per the WOZ reference, but does not fix this disk on its own.
- **Returning live `m_rsh` instead of `8'h00`** on a post-consume read.

### The question that is now actually narrow

Why does `flux_drive` emit no transitions for ~7 cells at the start of the first
sector read, when the drive reports ready and spinning, and never again on later
sectors of the same track? That is a startup/priming condition in the flux
generation path, and the cell trace above reproduces it in a 200-frame run.


### Traced through the drive: the drive is correct, the loss is at the cell boundary

Instrumenting `flux_drive`'s bitstream emission path (the second
`FLUX_TRANSITION <= 1'b1` site, ~line 1662 -- note the first site is the FLUX
track path and probing it yields nothing for a bitstream disk):

    EMIT pos=152..159  addr=19 data=96  bits 1 0 0 1 0 1 1 0   <- correct byte
    FLUXOUT pos=148 150 152 155 157 158 160 161 162 ...        <- both adjacent
                                                                  transitions ARE asserted

So the drive reads the right BRAM byte (`addr=19 data=96`) and asserts flux for
**both** of the adjacent 1-bits at 157 and 158, with `ld=1 rdy=1 wr=0`.

And the edges are not lost in the detector either. Counting over 400 frames:

    EDGESTATS: flux_high_cycles=690692 rising_edges=690692

Every `FLUX_TRANSITION` assertion is a clean one-cycle pulse and produces exactly
one `flux_edge`. Nothing is swallowed by the rising-edge detect.

Yet the IWM shift register still produces `90`. The two transitions the drive
emits at 157/158 arrive, and the shift register does not record them as two 1
bits. That places the fault squarely in the **cell-boundary alignment between
`flux_drive`'s `bit_timer` and `iwm_flux`'s `sr525_timer`** -- two independent
free-running counters -- rather than in the data, the emission, or the edge
detection.

That is the data-separator problem in its purest form, but note both separator
variants on `woz-separator-wip` were re-tested against this trace and the bits
at 157/158 are *still* missed, so re-phasing on the edge as implemented there is
not sufficient. The next attempt should work from the cell trace directly:
instrument `sr525_timer` and the drive's `bit_timer` together over cells 145-170
and find where a drive cell fails to line up with an IWM cell.


### Phase trace: edges ARE detected at the failing cells

Logging `FLUX_TRANSITION`, `prev_flux`, `flux_edge`, `sr525_timer` and
`FLUX_BIT_TIMER` together across the cells carrying the mis-decoded `0x96`:

    PH pos=155 drv=27 FT=1 prev=0 edge=1 sr=46 seen=0
    PH pos=157 drv=27 FT=1 prev=0 edge=1 sr=46 seen=0
    PH pos=158 drv=27 FT=1 prev=0 edge=1 sr=46 seen=0
    PH pos=160 drv=27 FT=1 prev=0 edge=1 sr=46 seen=0

`flux_edge` fires at 157 and 158 -- the two cells whose 1-bits go missing. This
**contradicts** the earlier conclusion in this file that "the IWM sees neither".
The edges are detected; the bits are lost somewhere between `flux_edge` and the
shift register.

The two counters are also in **fixed phase**, not drifting: the offset is a
constant 19 clocks (`drv=27 <-> sr=46`, `drv=2 <-> sr=21`, `drv=1 <-> sr=20`),
which is expected since `BIT_CELL_525` and `SR525_BIT_CELL` are both 56 with no
fractional term at timing 32. So each IWM cell contains exactly one drive
mid-cell instant, and two transitions cannot merge into one cell. That rules out
the drift/merge explanation for the data separator as well.

What remains: `flux_edge` is asserted, but `sr525_flux_seen` is not set (or is
cleared) before the shift at `sr525_timer == 1` consumes it. The next probe
should log `sr525_flux_seen` on **every** clock across cells 155-160 -- not just
at boundaries -- and find the cycle where it is cleared without a shift having
occurred.


## After the SmartPort flux fix (`8c4f9d7`): what is still wrong

The first-sector byte corruption is gone, but the disk still stops at the ROM
splash. Prologue counts over 400 frames, with the fix in:

    First Math   bytes=134665  addr=229  data=334     (was 228/333)
    DOS 3.3      bytes=135283  addr=345  data=343     balanced, boots

So the imbalance is essentially unchanged: we still find roughly two thirds as
many address prologues as data prologues, where they should be 1:1.

**The asymmetry lines up with sync length.** Measured on this disk's track 0,
address fields are preceded by only about **4** self-sync bytes while data
fields get **7-8**. We miss the ones with less sync. That says byte framing is
being lost routinely somewhere in the read path, and is only recovered when a
long enough sync run follows -- which is exactly why this disk is fragile and
DOS 3.3 (16 sync bytes before every address field) is not.

### Also eliminated

- **CPU reads do not disturb the shift register.** All three
  `clear_rsh_pending <= 1'b1` sites are byte-completion paths; none is in the
  read path, so the "reading clears the register mid-byte" theory is out.
- The PC histograms taken with `--fixed-time` and CPU tracing at 250+ frames are
  **timeout-truncated** and must not be used for before/after comparison -- both
  runs die at the same wall-clock point with identical counts regardless of
  behaviour. Use `--no-cpu-log` plus targeted counters instead.

### Where to go next

The remaining defect is a recurring loss of byte framing, not a single bad byte.
Given the read path is now verified correct end to end for an individual cell
(drive emits, mux passes, edge detects, register shifts), the next thing to
instrument is *where framing slips across a field boundary*: log the shift
register and cell counter continuously across the gap between a data field and
the following address field, and find the cell where the byte boundary moves.

Note this is the same underlying symptom the WOZ reference's LSS section
describes, and Bazyar's log records him eventually implementing the real logic
state sequencer rather than patching around it (`Docs/Woz.md`, "Thinking about
the LSS"). That may be what this ultimately needs.

## Sequencer semantics for 5.25" sync reads (First Math fixed)

The First Math trace settled what the "data latch lifespan" test actually
does. Its RWTS, after the `LDA $C08C,X / BPL` loop returns a D5:

    B958: nop
    B959: lda $c08c,x     ; second read, 8 cycles after the first, no wait loop
    B95C: cmp #$d5
    B95E: beq B972        ; D5 still latched -> protected address-mark path

Over 273 D5 hits in 300 frames the second read never matched, so the disk's
address marks are a D5 followed by extra zero bits, and the check relies on the
Disk II logic state sequencer holding a completed byte until the *next read
pulse* arrives (plus one cell). Neither the read-clears-it gate nor a fixed
"2 bit times + 4 CLK" timer (tried first; the IWM spec's phrase describes only
the adjacent-nibble case) can pass that.

`iwm_flux.v` now models the sequencer for 5.25" sync (non-latch) reads, after
OpenEmulator's abbreviated sequencer as used in GSSquared:

- QA=0: shift the cell's pulse in from the right, as before.
- QA=1: hold. A read pulse arms the restart; the next cell reloads the register
  with `{6'b0, 1, bit}`. Adjacent nibbles give the familiar 2-cell hold; trailing
  zero bits extend it. CPU reads never clear anything; the bus shows `m_rsh` live.
- Q6=1/Q7=0 (READLOAD): register fills with the write-protect sense bit and
  pulses are discarded, replacing the Q6-rising clear from `458dd35`. Same
  effect for the `LDA $C08D,X` re-framing trick, but bits arriving while Q6 is
  high are no longer accumulated (the P6 shifts WP in every LSS cycle instead).

WOZ Test Images, 1500 frames, `--fixed-time`: **19 -> 23 of 26 BOOTED.**

    BOOTED now:   First Math Adventures, DOS 3.2 System Master,
                  ProDOS User's Disk, Border Zone side A, Border Zone side B
    unchanged:    Hard Hat Mack, Stargate FAILED (GSSquared fails both on -p 5)

Bouncing Kamungas went BOOTED -> BLANK with the sequencer alone and came back
with the speed fix below.

Corpus spot checks against GSSquared `-p 5`:

- **The Halley Project** (the `458dd35` regression) boots: its E7/EE offset
  check passes, and at frame 2500 the screen matches GSSquared's frame 2500
  exactly ("Press any key to continue"). It is still BLANK at the corpus
  harness's 1200 frames because its loader reads one sector per ROM call with
  a seek check in between; the old "BOOTED" reference at 1200 was the ALERT
  loading splash, and GSSquared runs its floppy off the CPU clock so it is not
  frame-comparable. Retest it with `--frames 2500`.
- **Empire II** unchanged (ROM splash, as before).

Not a fix for the address/data prologue asymmetry story: that asymmetry was a
symptom of the constant recalibration, not its cause.

## Bouncing Kamungas: 1 MHz must persist through the motor-off holdover

With the sequencer change alone Kamungas stopped booting. Its trace showed the
right nibbles (the CPU-visible sequence matches the correctly framed track 0
stream at nibble ~725), yet 31 of 32 address fields failed their checksum.
The bus trace explained it: about 465 data-register reads per millisecond,
i.e. the CPU was at 2.8 MHz. The game's motor routine touches $C0E9 and then
$C0E8 immediately before its RWTS, and reads the sector while the drive coasts
through the IWM's one-second motor-off holdover. Its 4-4 decode re-reads the
register 11 cycles after each nibble, which is fine at 1 MHz but lands inside
the ~8 us sequencer hold at 2.8 MHz, so nibbles were read twice. (The old
clear-on-read shortcut hid this: a re-read returned 00 and the loop waited.)

`clock_divider.v` dropped slot-6 slow mode the instant $C0E8 was accessed. The
FPI follows the IWM drive enable, which stays asserted for the holdover second
when mode bit 2 = 0; Clemens models exactly this (`clem_iwm_speed_disk_gate` on
`CLEM_IWM_FLAG_DRIVE_ON`, held by `drive_hold_ns`). `iwm_woz.v` now exports
`IWM_ENBL` (its `iwm_active`, which already implements the mode-bit-2 holdover)
and `clock_divider` ORs `disk_motor_hold = iwm_enbl && !DISK35[6]` into the
slot-6 term. Kamungas boots.

Do NOT use `floppy_motor_on` (physical spin, unconditional 1 s) for this: the
ROM's boot-time 5.25" probe turns the motor off with mode bit 2 SET, so on
hardware the enable drops at once. Gating on the spin instead slowed every
HDD/3.5" boot by a second and broke five `regression.sh` screenshots (Total
Replay at frame 130 was still on its splash). With `IWM_ENBL` they match again.

GSSquared is NOT a reference for this class of bug: it clocks the floppy off
the CPU, so its CPU/disk ratio never changes and speed-dependent RWTS code
always works there.

## 202-disk corpus after the sequencer + speed changes

`test_woz_batch.sh --retest verify_p0.txt --frames 1200` on the combined
change, compared with `woz_sp` (the last full run before it; `woz_ref` is from
2026-08-28 and predates four other commits, so do not diff against it):

    IMPROVED  9   all nine "The Newsroom" revisions (the timing-34 disks):
                  TEXT_ONLY -> BOOTED
    REGRESSED 13  see below
    unchanged 180

The 13, rerun at 2500 frames and checked against GSSquared `-p 5`:

    Boot at 2500 frames (load-time shift from the 1 MHz motor-off holdover;
    these loaders turn the motor off between reads):
        Adventure Double Feature Vol II A, All About Light and Sound,
        Dinosaur Days Plus 2A, Empire II, Monstrous Monsters, Rampage,
        The Adventures of Sarah and her Friends
    Booted, sitting at a "type your name" prompt the harness scores TEXT_ONLY:
        Case of the Great Train Robbery, Simultaneous Linear Equations
    "Check startup device!" -- and GSSquared -p 5 shows exactly the same:
        Frogger, Maze Craze Construction Set, Quadrant 6112
    Garbage screen on GSSquared -p 5 as well:
        Mr. Do

So none of the 13 is a demonstrable regression; seven of them need more than
1200 frames now, which is a harness setting, not a bug. (Confirmed against a
clean build of the previous head, 5c5dfd0, in a worktree: 12 of the 13 were
BOOTED there at 1200 frames, so `woz_sp` was an accurate baseline.)

Frogger / Maze Craze / Quadrant 6112 are the ones to watch: they booted on the
old shortcut and stop at the IIgs ROM on both this core and GSSquared `-p 5`.
If someone can confirm they boot on a real ROM 3 IIgs, the sequencer hold is
too short and that is the place to look. ROM 01 (`--rom 1`) behaves the same
for all four, so it is not a ROM-revision difference in the boot code.

### Why Frogger (and its two siblings) stop at the IIgs ROM

Frogger's track 0 puts the data field two zero bits after the address field
(`... AA AA | 00 | D5 AA AD ...`, no address checksum or epilogue). Its D5
completes ~40 us after the ROM's last address-field read and, under the
sequencer hold, is replaced ~48 us after it (next pulse plus one cell). The
IIgs ROM's path from the track compare back to its poll loop is 50 cycles
(`C699..C6A4`, `C628`, `C656`, `C65E`), so at 1 MHz it returns just after the
hold ends and reads `AA AD ...` -- the bus trace shows exactly that. It then
never finds `D5 AA AD` and gives up with "Check startup device!". GSSquared
does the same on `-p 5` and boots the disk on `-p 2` (IIe ROM, shorter path).
The old clear-on-read model kept the D5 until the NEXT byte completed (32 us),
which is why these three used to "boot": the shortcut was too generous.

## Cross-check: Appletini One's Disk II (AppleWin's model on a real //e)

`/home/alans/mister/appletini-one/hdl/apple/disk2_card.sv` is a virtual Disk II
for a Zynq card that sits on a real Apple //e bus, so its read latch is
exercised by a real 6502 running real software; its acceptance list includes
"NIB and WOZ copy-protected reads". The WOZ read path is AppleWin's
(`woz_latch_delay_q` is AppleWin's `m_latchDelay`, and the Q6H comment cites
AppleWin's `LoadWriteProtect()`). Per bit cell:

    shift_next = {shift[6:0], bit}
    if delay != 0: delay = max(delay-4, 0); if shift_next == 0: delay += 4
    if delay_old == 0 or (delay_old <= 4 and shift_next != 0):
        latch = shift_next
        if shift_next[7]: delay = 7; shift = 0

Traced against our sequencer for the two cases that matter:

- Adjacent nibbles: byte completes (delay 7, shift 0); next cell's 1 makes
  shift 01 with delay_old 7, latch unchanged; the cell after that has
  delay_old 3 and shift 02|bit, latch takes the partial. Held 2 cells.
- Trailing zeros: each zero cell puts the delay back to 7, so the byte is
  held for the whole zero run, then 2 more cells once the first 1 arrives.

That is exactly `sr525_seq_armed`'s hold/arm/restart, including the
`{1, bit}` restart value. Reads never clear the latch; Q6H loads FF/00 by
write-protect state and discards pulses while Q6 stays high. So our 5.25"
read semantics now match AppleWin, GSSquared/OpenEmulator, and a hardware
card that boots protected WOZs on a real //e.

What it cannot settle: anything IIgs-specific. It is a Disk II card, not an
IWM, on a //e whose boot ROM returns to polling sooner than the IIgs ROM, so
Frogger/Maze Craze/Quadrant boot there for the same reason GSSquared `-p 2`
boots them. It also says nothing about the CYAREG motor-off speed holdover.

Worth borrowing later, both differ from ours: its MC3470 head window (4-bit,
one-cell-delayed output) and its weak-bit model (random 1 with probability
9830/32768 = 30% when the window is all zero, per the WOZ spec). The handoff
lists the head-window model as a dead end here, so re-try it only with this
implementation as the reference.
