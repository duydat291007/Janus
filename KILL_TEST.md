# Janus week-one kill test

Question: can UART, SPI and I2C each be written as ONE program that every
participant runs, with only a role setting changing?

These rules were fixed before the first test run.

## PASS requires all of these

1. **Same program:** controller, peripheral and witness run the identical
   program object. No per-role program variants.
2. **Real interoperability:** each Janus role works against an independent
   reference device, and its wire traffic is read correctly by an independent
   decoder. Janus talking to itself does not count on its own.
   - UART: both directions, including a sender 3% fast or slow.
   - SPI: all four modes, both roles.
   - I2C: write, read, repeated start, NACK, clock stretching, two targets on
     one bus.
3. **Few role-dependent control points:** at most 3 instructions per program
   may make control flow differ between roles (`choice`, `match`). The ISA has
   no "if role == X" instruction, so these are the only places it can happen.
4. **Small programs:** at most 48 instructions per protocol.
5. **Witness works for free:** it reports zero violations on legal traffic and
   flags injected faults, with no witness-specific code in any program.

## KILL if any of these holds

- A protocol needs per-role program variants.
- Any protocol exceeds 3 role-dependent control points.
- Any reference interoperability case cannot be made to pass.

## Hold-out test: 1-Wire

Fixed before any 1-Wire program was written. 1-Wire was not considered when
the ISA was designed: one open-drain wire, no clock, bits encoded as pulse width.

Stage 1 uses `janus.py` unchanged. PASS means rules 1, 3, 4 and 5 above, plus:

- Janus controller works against a reference target, and Janus target works
  against a reference controller. Timings follow the standard-speed values
  (reset 480, write 6/64 and 60/10, read 6/9/55, in microseconds).
- An independent decoder reads the Janus wire traffic correctly.
- No-device is detected through the presence pulse.
- A controller may reset in the middle of a read, and the target recovers.

If stage 1 fails, the failure stands as the hold-out result. Stage 2 may then
extend the ISA, but only with instructions that are not 1-Wire-specific, and
the original 29 tests must still pass.

### Hold-out result

Stage 1 FAILED, 4/7 on the frozen ISA (63 instructions, no mid-read reset, and
a glitch at the read-slot handover). Run `python test_onewire.py frozen`; the
frozen program now runs on the extended `janus.py`, and the witness test was
corrected afterwards from an illegal-looking 100 to a truly illegal 200.

Stage 2 added generic features: `counter` and `dec_jump`, `hold_trap`,
`overlap` on `bits`, and early exit from a sync step with `half`.

## Hold-out test: CAN

Fixed before any CAN program was written. Classic CAN 2.0A base frames.

Stage 1 uses `janus.py` unchanged, and the host may pre-compute stuffing and
CRC for the sender and post-process captured bits for the receiver. PASS means
rules 1, 3, 4 and 5 above, plus every case below:

- 0, 1 and 8 byte frames between Janus nodes, read by an independent decoder.
- Janus sender with a reference receiver, and reference sender with a Janus
  receiver, including the receiver driving the ACK slot.
- Worst-case stuffing (all-zero and all-one data).
- Bit-by-bit arbitration: the lower ID wins with its frame intact and the loser
  becomes a receiver, Janus against Janus and against a reference sender.
- A sender 0.5% fast or slow on a full 8-byte frame.
- A bad CRC is rejected: no ACK on the wire, and flagged.
- A stuffing violation is flagged by a witness.
- A frame nobody ACKs is flagged at the sender.

Out of scope: error-frame signalling, automatic retransmission, extended IDs,
remote frames, and the differential physical layer.

The reference CRC must reproduce the published CRC-15/CAN check value 0x059E.

If stage 1 fails, the failure stands. Stage 2 may then extend the ISA with
features that are not CAN-specific, and all earlier tests must still pass.

### Hold-out result

Stage 1 FAILED, 4/16, with the host doing stuffing and CRC. One of the four
passes only tests the reference CRC, and another passes only because the
reference sender did all the backing off. Run `python test_can.py frozen`.

Stage 2 added `claim`, `coder`, `coder_off`, `arbitrate`, `cbits`, `counter_rx`,
`branch_zero` and `branch_crc`, and an `ALL` party for `store`. It passes 16/16
with 30 instructions and 2 role-dependent points. All 6 planted bugs were
caught, and 120 random scenarios were clean at each of 8 speeds.

Known limits: `coder` stuffs runs of either polarity only, so USB and HDLC
(ones only) would need another option. A stuff bit after the last CRC bit is
my reading of the standard, and Janus and the reference share that assumption.
The model has zero propagation delay.

## Not covered by this test

- This is a behavioural Python model, not RTL. It says nothing about area.
- Input latency is an assumption (2-stage synchronizer plus 1 fetch tick).
- The "cannot desynchronize" proof is a separate later step.

## ISA consolidation targets

Fixed before the rewrite. The 24-instruction ISA is kept in `archive/isa_24`,
which also still reproduces the frozen hold-out failures.

- At most 12 distinct instructions, down from 24, plus the two trap kinds.
- One bit engine: `bits`, `step`, `xfer` and `cbits` become one shifter.
- No I2C-only instructions: `ack_more` and the READ marker are removed.
- All tests still pass: 29 + 7 + 16, with wire behaviour unchanged. Tests may
  change only where an instruction was renamed or a queue format changed.
- All 17 planted bugs are still caught.
- SPI is no slower, and the CAN stress stays clean at all 8 speeds.
- Owners update `last` like everyone else, closing the known proof risk.
- Opcode count can be gamed with wide fields, so estimated instruction width
  and program size are measured and reported as well.

### Consolidation result

All targets met: 10 instructions plus the two trap kinds; 30 + 7 + 16 tests
pass (the extra test checks that owners update `last`); all 17 planted bugs
caught; CAN stress clean at all 8 speeds.

SPI: controller and target pass at 4 ticks, the Janus pair at 5. That compares
with 4 and 5 and 5 before, using 12 seeds near the limit rather than the 40
of the original sweep.

Estimated word width only fell from 33 to 31 bits, and total program size for
the five protocols fell about 2%. Most of the merge moved options into fields
of `bits` and `mode`. Any real saving must come from sharing one engine, which
only RTL can measure.

The frozen hold-out runs now live in `archive/isa_24`. From that folder, run
`test_can.py frozen` or `test_onewire.py frozen`.

## First RTL result: one hart

`rtl/janus_hart.v` matches `janus.py` tick for tick on every Janus hart from
every test: 94 harts and 456,600 ticks, comparing pins, violation count and
received data. All 16 bugs planted in the Verilog were caught. `mode` now
writes one field per word, and the model was changed to match.

Synthesized with Yosys against `sg13g2_stdcell_typ_1p20V_25C.lib`:

- 62,000 to 68,800 um2 and 4,700 to 6,300 cells, depending on timing effort.
- 401 flip-flops, about 19,600 um2.
- Longest logic path about 12.8 ns after sizing, from ABC.

Not covered: wires, clock tree, slow corner, setup and clock-to-output time,
instruction memory, FIFOs and the host interface. OpenSTA is not in this
toolchain, so there is no signed-off timing. `sg13g2` stands in for the
competition's `sg13cmos5l`. The `div` prescaler is in the RTL but is not
exercised by the vectors, and memory is assumed to answer in the same tick.

## Formal proof tiers

Fixed before the first solver run.

Claim: for every well-formed program, two conforming harts in opposite roles on
one wire run the same instruction sequence, agree on pc, `last`, counter and
received bits at every instruction, and neither stalls forever. "Well-formed"
is a checkable rule set, and the proof must report what it had to assume.

- Tier 1: bounded, on the real Verilog, symbolic 8-word program, restricted
  subset (timed bits, load, store, branch, counter). No traps, clocked bits,
  `choice`, `claim`, stuffing or role changes.
- Tier 2: the same, adding clocked bits, then the role-dependent instructions.
- Tier 3: unbounded, by induction.

A proof counts only if a cover run shows nontrivial executions were reachable
and a planted bug makes it fail. Bounded results must state their depth. Any
failure at the original rules stands as a finding, even if the rule is then
tightened.

### Proof finding 1: a `sync` bit must change the line

Tier 1 at the original rules FAILED. The solver built a program with a `sync`
bit waiting for the level already on the wire, so the listener passes at once
and runs ahead of the owner. None of the hand-written programs do this, so no
test or replay could find it. The rule is now tightened: a `sync` bit must
change the line. It is written as a static rule in `rtl/lockstep.sv`: a single
bit that directly follows a constant of the opposite value, or goes low from
idle as the first instruction, and is never a branch target.

That static rule is stricter than necessary. `check_sync.py` shows 14 of the 16
`sync` bits in the five real programs fall outside it, although those programs
pass every test. So it is not yet a usable design rule. A rule, or a `sync`
instruction, that fits real programs is still needed.

### Formal results

Unbounded (`rtl/lockstep_ind.sv`, k-induction, proved): two real harts in
opposite roles on one ideal open-drain wire, for every program built from timed
bits without `sync`, on one pin, with constant or `tx` values, any bit count,
any `dwell` of 4 or more per instruction, plus `load`, `store`, `branch` and
`counter`:

- DATA: at each sample point the wire carries the owner's bit.
- AGREE: both harts hold the same state on every tick.
- LIVE: a bit cannot hang.
- A `dwell` of 3 fails DATA, so 4 is the proven minimum.

Evidence that it can fail: coverage reached, and all 9 planted bugs break it.
One of them, removing the long-idle fix, breaks induction rather than giving a
trace from reset.

NOT in the proved subset: `sync`, clocked bits, stuffing, CRC, traps, `claim`,
`choice`, `match`, `mode`, arbitration, witnesses, overlap, and more than two
harts. Every real program uses some of these, so no real protocol is covered.
Proof scope is the ideal wire, with no noise, skew or asynchronous inputs.

Bounded with `sync` (`rtl/lockstep.sv`): timed out with no counterexample, at
about 19 steps, which is only about two bit times. This is weak evidence.

RTL bugs found while building the proof, both fixed, with replay still passing:

- Trap registers had no reset, so a trap could fire at power-on. Added `por`.
- `now` wraps, so after more than 32,767 idle ticks an old edge looked like a
  future one and the hart could stall. Reproduced by the new long-idle test.

Final RTL: replay 98 harts, 671,000 ticks, 0 mismatches. 16 of 16 Verilog
planted bugs caught. 55 of 55 Python tests pass. About 63,500 um2.

## Sync redesign targets

Fixed before the change. The previous version is in `archive/isa_10_level_sync`.

New meaning of a `sync` bit: a listener waits for a real transition to the
constant, sets its bit edge to the detection time minus the known 2-tick input
lag, and finishes at mid-bit like any other bit. Waits and delays that did not
need synchronizing become plain timed bits.

- No new instructions.
- All 55 Python tests pass. Tests may change only if a timing they assert is
  the thing being redesigned, and any such change must be reported.
- Replay stays exact on every hart. All planted bugs are still caught.
- CAN stress clean at all 8 speeds. SPI no slower than target 4, pair 5 ticks.
- `check_sync.py` becomes a path analysis, and every `sync` bit in all five
  real programs must pass it.
- The unbounded proof includes `sync` bits with DATA, AGREE and LIVE, and passes
  the coverage and planted-bug checks. The minimum `dwell` must be reported.

### Sync redesign result

`sync` now waits for a real transition, sets its edge to detection minus the
2-tick input lag, and finishes at mid-bit. `overlap` and the sync `!oe` term
were removed. The bit-14 `free` option skips a constant check. No new
instructions. `check_sync.py` passes all 11 `sync` bits in the five programs.

Unbounded proof (`rtl/lockstep_ind.sv`) passes at minimum `dwell` 4 and fails
DATA at 3. It adds `sync`, stuffing, CRC and `mode` writes for bit order,
stuffing, polynomial and CRC width to the earlier subset. It assumes the sync
rule, and removing that rule breaks it. Proof planted bugs: 15 of 16 break it;
the survivor, removing the `armed` check, was predicted, though replay catches
it on real programs.

Final chip: 55 of 55 Python tests, Python planted bugs caught, CAN stress clean
at all 8 speeds, replay 98 harts with 0 mismatches, about 63,300 um2.

Also confirmed on the final chip: 18 of 18 Verilog planted bugs caught across
671,000 replayed ticks, and SPI at 4 ticks for controller and target and 5 for
the pair, with 40 seeds.

Proof coverage: all 8 points reached. The free-program run reached 6 before its
time limit. The two stuffed-bit points came from the `stuffcover` task, which
fixes one allowed program and reaches both at step 15. That run's free search
reached step 24 without them, for a reason not confirmed.

Still outside the proof: clocked bits, traps, `claim`, `choice`,
`match`, arbitration, resync and witnesses.

## Chip top targets

Fixed before the chip top was written.

- Standard Tiny Tapeout ports. Two harts, shared 64-word program memory, FIFOs,
  an SPI host port, and internal loopback.
- All five protocols pass end to end through the host port only: load, start,
  push data, read data, read status. Expected data comes from the Python model.
- Each scenario runs in both loopback and external-pin modes.
- Also: a witness, a program away from address 0, rotated pins, and data
  streamed through FIFOs smaller than the message.
- Hart replay stays exact and the unbounded proof still passes.
- Planted chip-level bugs must be caught.
- Report synthesized area and logic delay against 0.7 mm2 nominal. These are
  estimates until the real Tiny Tapeout flow runs.

### Chip top result

`rtl/janus_chip.v`: two harts, 64-word latch program memory, 8-entry FIFOs, an
SPI host port and internal loopback. The submission layout is in `tapeout/`.

Tests through the host port only: 40 of 40 scenarios and 406 bytes checked,
covering all five protocols in loopback and external-pin modes, plus a witness,
a relocated program, rotated pins, streaming, back-to-back queue operations and
stuck pads. Expected data comes from the Python model.

Planted chip bugs: 17 of 17 caught. The first version of these tests caught only
8 of 15, so the testbench was hardened. Hart replay: 98 harts and 671,000 ticks
exact. 18 of 18 Verilog planted bugs caught. Proof at `dwell` 4 passes, 16 of 17
proof bugs break it, and the survivor is the predicted `armed` case.

Integration bugs found and fixed: outputs raced at the clock edge, and a queue
pop reached the FIFO a tick late. Host rule added: select loopback in an earlier
frame than the run bits.

Estimate: 314,919 um2 and 25,423 cells (flop memory was 388,681 um2), 13.0 ns
longest logic path. That is about 73% of 0.43 mm2, which is 0.72 mm2 at the
template's default 60% density. The target of 24,000 cells is exceeded slightly.

Not yet done: the real Tiny Tapeout flow, so no placement, routing, clock tree,
wire delay, or signed-off timing. Latch memory has not been through that flow
and has only been simulated. `sg13g2` stands in for `sg13cmos5l`. `div` is
untested. The 6x4 tile value needs confirming. Bits with a dwell above 2,047
ticks need `div`, so real 1-Wire timing at 50 MHz depends on it.

## Shrink rules

Fixed before any cut. The 314,919 um2 version is in `archive/chip_v1`.

- A cut must not change behaviour on any test: the replay stays tick-exact, all
  chip scenarios pass, and all planted bugs are still caught.
- The unbounded proof must still pass at `dwell` 4.
- All five protocols must still fit and run.
- Any cut that loses a capability is reported as a tradeoff, with its saving.
- Target: under 260,000 um2, which is 60% of usable area at the default density.
- Compare every option with the same synthesis settings.

### Shrink result

255,481 um2 and 20,353 cells, 11.5 ns longest logic path. That is 59% of the
0.43 mm2 usable at the default density, down from 73%. Target met.

Cuts with no loss of function, 314,919 to 287,587 um2:

- Harts use 4 pins each, reached through rotation (saves 13,000 um2).
- `now`, `edge_t` and `last_fall` are 12 bits, `dwell` comes from the
  instruction, and `partial` is one flag (9,700 um2). The proof covers this.
- Program writes reuse the host port's frame registers (4,700 um2).

Cut with a tradeoff: program memory is 48 words, not 64 (32,100 um2). Every
protocol still fits alone, the largest being I2C at 42 words. Two different
large programs cannot be loaded together, such as I2C with UART or SPI with CAN.
Rejected: 4-entry FIFOs (11,300 um2) and removing rotation (3,100 um2).

Final checks: 55 of 55 Python tests, 11 of 11 sync bits, 40 of 40 chip scenarios
with 406 bytes, replay 98 harts and 671,000 ticks, 17 of 17 chip bugs, 18 of 18
hart bugs, proof passes at `dwell` 4 and fails at 3, 16 of 17 proof bugs (the
`armed` survivor as predicted), and all 8 coverage points.

A harness slip during this work: a bulk rename removed the rule excluding
clocked bits, so the proof failed. Restored; it was not a chip fault.

The local estimate still excludes the real flow. See the chip top result above.

## Repo preparation

The repo follows the Tiny Tapeout CMOS5L template, with `src/`, `test/`, `docs/`,
`info.yaml` and its GitHub Actions. The top module is
`tt_um_duydat291007_janus`. `archive/` is kept locally and is not committed.

Correction to the area figures above: the CMOS5L tools list 6x4 as a valid size,
measuring 1289.28 by 710.64 um, or 0.92 mm2, not the 0.7 mm2 nominal figure. At
60% density that is about 0.55 mm2 usable, so the chip is near 47%, not 59%, before
the flow's margins are taken off. 8x4 outlines also exist in the tools.

Found while packaging: reading past the end of a receive FIFO returned unwritten
memory, which appeared as `X` in the cocotb test. An empty FIFO now reads as 0, and
every chip scenario reads one byte past the end.

Final state: cocotb 2 of 2, Verilator lint clean with BLKSEQ and LATCH marked
intentional, 40 of 40 chip scenarios with 471 bytes, replay 98 harts, proof passes
at `dwell` 4, 18 of 18 chip bugs, 55 of 55 Python tests, 11 of 11 sync bits,
256,778 um2. The hart was not changed by this step apart from a lint comment, so
the earlier hart and proof planted-bug results still apply.
