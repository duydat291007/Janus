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

### First real flow run

The first Tiny Tapeout GDS run failed after 2 h 43 m inside `Yosys.Synthesis`.
FSM extraction tried to re-encode the hart's state register and wrote over a
million transition lines. Local synthesis had always passed `-nofsm`, a setting
that never reached the shipped sources. Reproduced locally: default synthesis on
the old sources timed out at 600 s. Fixed by marking the register
`fsm_encoding = "none"`, after which default synthesis finishes in 7 s. Lint,
cocotb, chip tests, replay and proof all pass, and area is unchanged.

`rtl/default_synth.sh` runs synthesis the default way, so the shipped sources
are tested without local workarounds.

### Second real flow run: setup timing

The second run finished every stage, passing DRC, LVS and antenna checks with no
hold violations. It failed setup at the typical corner, the only corner the flow
treats as an error: worst slack -2.96 ns at 20 ns, with 101 endpoints failing.
The slow corner was at -16.5 ns, and the fast corner passed.

The sign-off reports showed two ways into the hart's long same-tick chain:

- The fetch. Each bit of the binary `pc` steered hundreds of mux cells, so the
  read took about 8 ns before the hart saw its instruction.
- The trap configuration. `cfg` was written at the top of the clocked block and
  read by the traps in the same tick, which put the reset pin and the host
  port in front of the trap logic.

Fixes, neither of which changes what a program does:

- The hart also registers its pc as one-hot, `pc_sel`. Each fetch is then an
  AND-OR over the 48 words, and each select bit drives 32 gates. A pc past
  word 47 now fetches 0, where before it read off the end of the memory.
- `cfg` is written after the traps read it, so a write takes effect one tick
  later. The replay writes configuration only while the hart is held, the
  proof never writes it, and a host frame takes many ticks.

Local synthesis cannot see this. It has no wire or fanout model, and it put the
chip at 11.4 ns before the change. Only the real flow measures it.

Checks after the change: cocotb 2 of 2, 40 of 40 chip scenarios with 471 bytes,
replay 98 harts, 55 of 55 Python tests, 11 of 11 sync bits, proof passing at
`dwell` 4 and failing at 3 as before, all 8 coverage points, 18 of 18 hart bugs,
16 of 16 proof bugs plus the expected survivor, and 20 of 20 chip bugs. The
fetch bug was rewritten for the new read, and two more target it: a fetch that
also reads the next word, and a one-hot pc a tick late. The replay feeds the
hart its instruction directly, so only the chip tests can catch the second.
Area estimate 246,717 um2, down from 256,778: the AND-OR is smaller than the
mux tree. Default synthesis takes 6 s. Lint adds two warnings, both
intentional: the binary pc is left unconnected in the chip, and the top 16
bits of `pc_sel` are unused.

### Third real flow run: timing met

The rebuild passed every flow stage and the Tiny Tapeout precheck. Setup slack
at the typical corner is +0.52 ns, up from -2.96 ns, so the margin is thin. The
slow corner improved from -16.5 to -11.1 ns; the flow does not check it. The
run took 3 h 43 m, against 1 h 32 m before.

The gate-level test failed twice. The first time, GitHub timed out serving the
simulator download, so nothing ran. On the re-run, UART failed and I2C passed:
a status byte read back over SPI held an X.

Traced on the real netlist: the X came from one flop, bit 3 of hart 1's
transmit FIFO write pointer, which never left X after reset. Synthesis had
folded the synchronous reset into the increment logic as a choice selected by
that same bit. Both choices are 0 during reset, but a simulator cannot know
that while the select is X, so the bit stayed X. In silicon the flop holds a
real value and resets correctly, so this was a simulation-only failure. A first
guess, that unwritten FIFO memory was the source, was tested by zeroing that
memory, and it was wrong.

Fix: the FIFO pointers now reset asynchronously, through the flops' reset
pins, so no logic sits between the reset and the flop. The memory write keeps
its old condition in a separate block. Checked by synthesizing locally to the
same CMOS5L cells and running the gate-level test: the old sources show the
same stuck pointer bits, in two FIFOs, and fail; the new sources reset every
pointer and pass 2 of 2. Also: 40 of 40 chip scenarios, 20 of 20 chip bugs,
cocotb 2 of 2 on RTL, default synthesis 5 s. The hart is unchanged, so replay
and proof results still apply. Lint adds `SYNCASYNCNET`, because `por` is now
both an asynchronous and a synchronous reset; that is intended.

### Fourth real flow run: clock lowered to 25 MHz

The build with the FIFO reset fix passed every check except setup timing at
the typical corner, where 8 endpoints failed. The build before it had passed
the same corner by only +0.52 ns. At 50 MHz the design sits on the edge, so
small layout changes decide pass or fail, and each attempt takes about four
hours.

The target clock is now 25 MHz (`CLOCK_PERIOD` 40 in `src/config.json`,
`clock_hz` in `info.yaml`). No logic changed. Janus counts time in clock
ticks, so programs set `dwell` for the clock, and the model, replay, proof
and tests are unaffected. Costs: one tick is 40 ns instead of 20 ns, the
fastest protocol rates halve (SPI near 3 MHz instead of 6), and the host SCK
limit of 1/8 of the clock becomes about 3.1 MHz. The slow corner, which was
11 ns short at 50 MHz, may now pass too. Raising the clock again is future
work: the remaining slow path is the hart's same-tick chain.

### Prescaler test, and power-on reset made asynchronous

Definition fixed first: with prescaler D (`mode` field 12), a hart must match
the model exactly with every tick lasting D+1 clocks. `rtl/div_replay.sh`
replays all 98 recorded harts that way, holding each tick's inputs for D+1
clocks, and `rtl/tb_div_mode.v` checks that a program can set the prescaler.

The first run failed 87 of 98 harts at D = 1 and D = 3. The prescaler only
slowed `now`. Instructions, input sampling, clocked bits, hold traps and the
`sync` lag all still ran every clock, so a prescaled hart ran ahead of its own
timer. Any program using `div`, such as 1-Wire with its 480 us reset, would
have mixed time units in silicon. Fixed by making the prescaler a clock enable
for the whole hart: between ticks it only counts. At D = 0 every clock is a
tick, so nothing else changes. After the fix: 98 of 98 at D = 0, 1, 2, 3 and 7.
Planted prescaler bugs: 4 of 4 caught (prescaler ignored, counter steps by 2,
field 12 ignored, inputs sampled every clock), each by at least one test.
The assembler still cannot name field 12; programs set it with a raw word.

Local gate-level simulation of that change then failed: bit 0 of hart 0's
`now` never left X during reset, the same trap as the FIFO pointer. Its next
value was built as `~((~q & a) | (q & b))`, which is 0 during reset in silicon
but stays X in simulation while q is X. Rather than fix registers one at a
time, power-on reset now goes to the flops' reset pins across the chip: hart
state, the trap configuration (now six registers instead of an array), unit
registers, the program write pulse and the host port. The synchronous `rst`
that holds a hart still loads its real starting values afterwards. No
synchronous resets remain; the only flops without a reset are the FIFO
memories, which are never read before they are written. Local gate-level run:
2 of 2, and no flop left X after reset in the bits the scan could match.

Checks: replay 98, prescaler replay 98 at D = 1, 3, 7, directed prescaler test,
40 of 40 chip scenarios with 471 bytes, cocotb 2 of 2, 18 of 18 hart bugs (one
pattern retargeted for the renamed trap registers), 20 of 20 chip bugs, proof
at `dwell` 4 passes and fails at 3, 16 proof bugs plus the expected survivor,
all 8 coverage points, default synthesis 6 s. The `stuffcover` task now
finishes inside its time limit, so it reports the six points that only the
free-program task reaches as unreached; it reaches both of its own at step 15.

### Sixth real flow run: routing congestion, density lowered

The build with the prescaler fix and asynchronous reset passed every stage up
to detailed routing, then hit GitHub's six-hour job limit there. The router
started with 18,652 violations, reached 7, and spent hours on "stubborn tiles"
passes without clearing them. The passing 25 MHz build had started from the
same state (18,467 violations, placement congestion 1.05 against 1.047) and
happened to finish routing in two hours. So the design sits at the edge of
routability, and build time varies widely between runs.

The cells use about 31% of the tile, but the template placed them at 60%
density. `PL_TARGET_DENSITY_PCT` is now 45, so cells spread over more of the
tile and leave more room for wires. No logic changed. The heaviest wiring is
the program memory: 1,536 latches, each feeding both harts' fetch logic.

Result: the build at 45% density passed every job: the full flow at 25 MHz
in 2 h 50 m (detailed routing converged), the Tiny Tapeout precheck, the
gate-level test and the 3D viewer. This is the first build to pass all
checks with the prescaler fix and asynchronous reset included.

### 1-Wire at real timing

The 1-Wire program counts one tick as one microsecond. Programs can now name
the prescaler (`mode div=...`, field 12); the model accepts it and ignores it,
since a model tick is a prescaled tick. `protocols.onewire(24)` sets 1 us ticks
at 25 MHz. A new model test runs a Janus controller, target and witness at that
setting against the reference decoder: 8 of 8 1-Wire tests pass.

The replay bench now follows the hart's own ticks, so a program may set its
own prescaler, and it checks the cadence: each tick must last exactly
prescaler + 1 clocks, and the prescaler a hart ends with must match the
model's. The three real-timing harts take 437,452 clocks for 17,500 ticks:
two single-clock ticks, then 17,498 at 25 clocks. Planted bugs: a counter
stepping by 2 fails at tick 2, and an ignored field 12 fails on the final
prescaler. Two chip scenarios run the same exchange through the host port in
loopback and on the pins, 42 of 42 chip scenarios in all. They show the
transfer completes; the replay is what pins down the timing.

### Speeding up the hart without changing behaviour

At 50 MHz the clock had been limited by the hart's tick logic. Removing all
same-tick fall-through, one state per tick, would cut the hart's logic delay
only from 11.2 to 10.4 ns in local synthesis against the CMOS5L library, so
the tick semantics were not the problem. The longest path showed two false
paths instead, where synthesis chained logic that can never act in the same
tick:

- Traps changed the state the program logic then read, although the program
  logic is skipped whenever a trap fires. Traps now decide first without
  changing state, then either fire or the program runs. The last trap to fire
  sets the target, as before. 11.2 to 9.9 ns.
- After EXEC a tick runs either the clocked-bit states or the others, never
  both, but they were written in series. They are now two branches. Down to
  6.0 ns, 46% less than before, with 5% less area.

Both are behaviour-preserving: replay 101 harts with cadence checks,
prescaled replay at 1, 3 and 7, 42 chip scenarios, cocotb 2 of 2, local
gate-level 2 of 2, 18 of 18 hart bugs (one pattern retargeted), 20 of 20 chip
bugs, 16 proof bugs plus the expected survivor, proof at `dwell` 4 passes and
fails at 3, all 8 coverage points, 55 + 1 Python tests, 11 of 11 sync bits.
These are logic-only figures; the real flow adds wires and the fetch.

### 50 MHz closes; moving to 8x4 tiles and 64 words

With the faster hart, a build at 50 MHz on 6x4 tiles passed every job: the
full flow with timing, the Tiny Tapeout precheck, the gate-level test and the
viewer. The same design at 25 MHz passed too.

The organisers then confirmed 8x4 tiles as final, and the template's main
branch moved to the `ttihp27a` actions. The design now uses 8x4, the CI files
match the template, and program memory is back to 64 words, since the 48-word
cut was made only for area. A new chip scenario runs a program from word 56,
so the restored top words are used. The 48-instruction rule from the kill
test stays as a separate design rule on program size.

Checks: 32 + 8 + 16 Python tests, 44 of 44 chip scenarios with 511 bytes, 20
of 20 chip bugs, replay 101 harts, cocotb 4 of 4 on RTL and on a local
gate-level netlist with no flop left X after reset, default synthesis 6 s.
The hart did not change, so its proof and planted-bug results stand.

## Hold-out test: low-speed USB

Fixed before any USB program was written. Low-speed USB is one of the
organisers' stretch goals and was not considered when the ISA was designed.
Scope is the packet layer at 1.5 Mbit/s: a differential pair, NRZI coding,
bit stuffing after six ones, CRC5 and CRC16, and an SE0 end of packet.

Stage 1 uses `janus.py` unchanged. As for CAN, the host may pre-compute NRZI,
stuffing and CRCs for the sender and post-process captured bits for the
receiver. PASS means rules 1, 3, 4 and 5 above, plus every case below:

- A Janus host sends an OUT token and a DATA0 packet of 8 bytes; a reference
  device answers ACK. An independent decoder reads every packet: PID, address,
  endpoint, CRC5, data, CRC16 and EOP.
- A reference host to a Janus device, and Janus to Janus, the same way.
- The device answers within the turnaround window, and a Janus host that gets
  no answer reports a timeout.
- A sender whose clock is 1.5% fast or slow, on a full 8-byte data packet.
- A witness flags a bit-stuffing violation (seven ones), a bad CRC16 and a
  missing EOP, with no witness-specific code.
- D+ and D- are complementary except during SE0, and the bus idles in J.

Out of scope: enumeration, keep-alive, full speed, the electrical layer,
suspend and resume, and hubs.

Assumptions to check against the USB 2.0 specification, chapter 7, since the
sources found do not state them: a reply within 2 to 7.5 bit times, a host
timeout of 16 to 18 bit times, and a low-speed clock tolerance of 1.5%.

If stage 1 fails, the failure stands. Stage 2 may then extend the ISA with
features that are not USB-specific, and all earlier tests must still pass.

### Hold-out result, stage 1

Stage 1 FAILED at the first case. With the host pre-coding NRZI, stuffing and
CRCs, a Janus host sent an OUT token and a DATA0 packet; the reference decoder
found 0 packets, and the line was never once in state K. A timed `bits`
instruction drives one pin and `set` drives only a constant, and no
instruction branches on the bits being sent, so no program can drive D- as
the complement of data on D+. Every later case depends on a valid K state, so
none can pass either. Run `python test_usb.py`.

The reference side was checked first: CRC5 matches the published USB example
(address 0x15, endpoint 0xE gives 0x17), CRC16 matches the CRC-16/USB
catalogue check value 0xB4C8 once bit order is accounted for, and the decoder
recovers a token and an 8-byte data packet sent by the reference sender.

What stage 2 would need, all generic: a complementary pin pair, NRZI line
coding, stuffing of ones only (HDLC and USB both use it), and CRCs that start
from all ones and are sent inverted, which most serial CRCs do.

### Hold-out result, stage 2

The stage 1 failure stands. Stage 2 extends the ISA and PASSES every
pre-registered case, with all earlier tests unchanged. Run `python test_usb.py`;
`python test_usb.py frozen` still shows the stage 1 failure.

What was added, none of it named after USB:

| Addition | Where | What it does |
|---|---|---|
| `pair` | mode field 13 | Timed bits drive a second pin as the complement |
| `nrzi` | mode field 14 | A 0 is a change of level, a 1 is none |
| ones-only stuffing | bit 4 of `stuff` | Count only 1s and stuff a 0 |
| CRC start and restart | bit 5 of `width` | The CRC restarts at all ones; a `width` write restarts it |
| `resid` | mode field 15 | The CRC value `crc_bad` accepts |
| break | bit 13 of `bits`, mode field 16 `on_break` | Drive both pins low; a listener that samples a break jumps |

One planned feature was not needed and was left out: sending the CRC
inverted. The host queues the CRC bytes and the chip checks the residual.

The program (`protocols.usb`) is 46 instructions with 2 role-dependent ones:
the `choice` that ends a packet and the `on_break` jump, which only listeners
take. It is the same program for host, device and witness, and the witness has
no code of its own.

Results, 14 cases:

- Janus host to a reference device, a reference host to a Janus device, and
  Janus to Janus over 300 random payloads of 0 to 8 bytes: the independent
  decoder reads the token, the data packet and the ACK, with good PIDs, CRC5,
  CRC16 and EOPs; no violations and no bus contention.
- The device answers 2.12 bit times after the EOP. A host with no device
  counts a violation 17.19 bit times after the EOP, then runs its next
  transaction cleanly.
- A sender 1.5% fast or slow: 45 payloads at each rate, all received and
  answered, including all-ones and all-zeros data.
- The witness flags seven ones in a row, four different CRC16 errors, a
  missing EOP, an EOP inside a byte, and an EOP of one bit time. For the
  first three the device stays silent and the next good transaction is
  answered.
- The wire is only ever J, K or SE0, idles in J, and holds SE0 for exactly
  two bit times at each of the three EOPs. No bit edge is late.
- 12 of 12 bugs planted in the model or program are caught
  (`python test_usb.py mutants`).

The Verilog: 286 recorded harts replay tick for tick, 185 of them USB, and
again with the prescaler at 3 and 7. Chip
scenarios are 48 of 48 with 559 byte checks, including a USB transaction and
a USB timeout through the host port, in loopback and on the pins.
Planted bugs: 32 of 32 in the hart (14 of them in the new logic), 20 of 20 in
the chip, and 16 proof bugs plus the expected survivor. One new hart bug
survived the first run, a listener not checking a break bit; the short-EOP
case was added for it and now catches it. Three proof bugs were retargeted
to renamed lines.
The proof passes at `dwell` 4 and fails at 3 as before, for its subset, which
now explicitly excludes the new modes. It failed once on the way: a register added for NRZI was not covered
by the invariant, so the register was removed. Cost: 60 flops and 3.2% area
(274,648 to 283,565 um2 synthesized); the estimated critical path goes from
6.3 to 6.5 ns. This version has not been through the Tiny Tapeout flow yet.

Limits, stated plainly:

- The chip's queues hold 8 entries. A token and a full 8-byte data packet are
  16 entries, and one USB byte lasts 5.3 us; no way for the host port to
  refill or drain the queues that fast has been shown. The 8-byte cases pass on the model and in the hart replay, where the
  queue is not limited. Through the real queues only a transaction with an
  empty data packet fits, and that is what the chip scenarios run.
- The host supplies the CRC5 and CRC16 bytes. The chip checks CRC16 and does
  not check CRC5.
- The device does not filter by address or endpoint: it answers any good data
  packet. `match` cannot mask the endpoint bit that shares the address byte.
- Only OUT with ACK. No IN, no SETUP sequence, no data toggle, no NAK or
  STALL, no enumeration. It cannot be plugged into a PC as a working device.
- A timeout is reported as a violation count, not as a status of its own.
- After an EOP the sender drives J for two bit times; the specification asks
  for one.
- It needs a 24 MHz clock. At the 25 MHz in `info.yaml` the bit rate is 4%
  high, outside the tolerance.
- Simulation only. Pins are sampled single-ended on D-, and the pull
  resistors and voltage levels are outside the chip.
- The reference device and decoder were written for this test from the
  specification, by the same author as the chip. They are independent code,
  not an independent implementation. The three assumptions listed above are
  still unchecked against the specification text.
- The reference host idles for four bit times after reset before its first
  packet; a Janus device needs about a dozen ticks to run its set-up.
- `check_sync.py` does not cover `sync` bits under NRZI.
- The reference decoder was changed after stage 1: it hung when a trace ended
  inside a packet. No decoding rule changed.

### After stage 2: 16-entry queues

The stage 2 build passed the Tiny Tapeout flow: layout, precheck and the
gate-level test.

The first limit above is now removed. Both queues of each hart went from 8 to
16 entries, which is exactly what a token and a full 8-byte data packet need
to send (16 entries) and more than the device needs to receive (14 bytes).
Two chip scenarios run the 8-byte OUT transaction, with stuffed bits, through
the host port and the real queues, in loopback and on the pins: host with
device, and host with witness. Chip scenarios are 52 of 52 with 639 byte
checks. 20 of 20 chip planted bugs are caught, and cocotb is 4 of 4.

Cost: 294 flops and 8.9% area (283,565 to 308,867 um2 synthesized). The
queues are exactly full in that transaction, so a longer packet or a second
transaction queued early would still overflow. The hart did not change, so
its replay, proof and planted-bug results stand. This version then passed
the Tiny Tapeout flow: layout, precheck and the gate-level test.

## Adversary: a hart that sends one bit wrong

Not a hold-out test: this was built after the USB result, to attack the
design with itself. Any hart can be made an adversary through host register
11. It runs its program unchanged but drives the wrong level for one chosen
timed bit it owns, once. `test_adversary.py` sweeps that fault over every bit
a sender owns and states what the other harts must do. Clocked bits (SPI,
I2C) have no fault injection.

It found three bugs, all fixed:

1. A sender fed its CRC and its stuffer with the bit it read back, not the
   bit it meant to send. A corrupted data bit in a CAN frame therefore went
   into the sender CRC too, and every receiver accepted the wrong frame: 47 of
   82 fault positions delivered wrong data with no violation anywhere. This
   was in the hart, not in the CAN program, so noise on a real bus would have
   done the same. An owner now codes the bit it meant to send.
2. A USB host whose queue ran dry inside a packet sent 0xFF bytes for ever,
   because only a STOP entry ended a packet. An empty queue now ends it too,
   and the host waits for queued data before every packet.
3. The model let the loop counter go below 0 where the Verilog stops at 0.
   The replay caught it as 2 mismatching harts of 577. The model was wrong.

Results after the fixes:

- CAN, sender adversary: all 82 positions are flagged by the witness, no
  wrong frame is accepted, the bus goes idle and the next frame is clean.
- USB, host adversary, 139 positions: every fault in the data and CRC16 is
  flagged and never answered with ACK. An ACK always means the data bytes
  were right. The bus recovers after every position. 31 positions go
  unnoticed, all in the token or a PID byte, because the chip checks neither
  CRC5 nor the PID. That is a real gap, not a rounding error.
- USB, device adversary, 19 positions in the handshake: none leaves the host
  with a clean ACK byte and no violation.
- UART: a wrong stop bit is flagged. A wrong data bit arrives as a wrong
  byte and nothing can tell, since UART has no redundancy.
- 3 of 3 planted bugs are caught (`python test_adversary.py mutants`).

Checks: the 70 earlier model tests are unchanged. The Verilog replays 457
recorded harts tick for tick, the adversary runs among them at every sixth
position. Chip scenarios are 62 of 62 with 815 byte checks, ten of them
adversary runs through the host port.
The prescaler replay passes at 3 and 7. Planted bugs: 38 of 38 in the hart,
six of them in the new logic (one older bug retargeted to a changed line),
20 of 20 in the chip, and 16 proof bugs plus the expected survivor. The proof
passes at `dwell` 4 and fails at 3 as before; its subset excludes the
adversary, and it now covers the coder following the owner's intended bit.
Cost: 54 flops and 1.5% area (308,867 to 313,360 um2 synthesized); the
estimated critical path goes from 6.5 to 6.8 ns. This version then passed the
Tiny Tapeout flow: layout, precheck and the gate-level test. The build's
viewer page failed to publish, on a missing GitHub Pages artifact; that step
does not involve the design.

Limits: one fault per run, in timed bits only. The fault is a wrong level
for a whole bit; it cannot shift an edge, shorten a bit or add a glitch. The
recovery checks queue the next frame after the bus is idle; bytes left in a
queue by a cut-off frame are sent as bogus frames first, and are flagged.

## Review: everything read again

After the adversary, the model, the Verilog, the tests and the scripts were
read again line by line. No test was failing. Found and fixed:

1. The violation counter wrapped. It is 8 bits in the chip, and the 256th
   violation took it back to 0: the "violation seen" pin went low and a host
   read a clean count from a very bad run. A witness left watching a noisy
   bus would get there. It now stops at 255, in the Verilog and in the model.
   No test had counted that far. `test_violation_count_stops_at_255` does,
   and the replay holds the Verilog to it.
2. A queue could lose a byte without saying so. A full queue refused a push
   even in a tick that popped an entry, while the overflow flag assumed the
   pop had made room. A byte arriving in the same tick as a host read of a
   full receive queue was dropped with the flag clear. A full queue now takes
   a push in a tick that pops. The chip scenarios cannot place two events on
   one tick, so the queue has its own testbench against a plain list
   (`rtl/tb_fifo.v`, run by `chip.sh test`): 20,000 random ticks, 1,987 of
   them a push into a full queue with a pop. The old queue fails it.
3. The assembler encoded out-of-range values silently. A third edge trap
   overwrote a hold trap's word, and a constant too wide for its field ran
   into its neighbour. No shipped program did either. It now refuses.

Removed: a flop per hart that always held the opposite of another (`saved`
and `stuff_bit`); two scripts whose patterns no longer matched the source
(`rtl/variants.sh`, `rtl/area.sh`); the early instruction-width estimator
`isa_report.py`, superseded by the real encoder and wrong for six programs;
dead decoding code in `rtl/cex.py`; an unused import. `sweep.py` reported
speeds for a 50 MHz clock, as did the CAN stress run; both now use the chip's
25 MHz.

Removing the flop showed a weakness in the proof. Its planted bug "stuff bit
wrong polarity" had been caught only through that flop. With the flop gone
the two harts agreed with each other on the wrong polarity, and the proof
passed. The proof now states the property itself: a stuff bit is the opposite
of the run it follows. The replay had caught this bug all along.

The proof also gained a claim: both harts hold the same violation count at
every tick, so a listener never flags what a conforming owner sent. A new
planted bug, a listener that flags a good constant bit, breaks it.

Added: a cocotb test of the USB transaction below, which the Tiny Tapeout
flow also runs on the gate-level netlist; a GitHub workflow that runs the
model tests, the replay and the chip scenarios on every push; and the replay
and chip scripts now exit with an error when anything fails.

### The chip sends the CRC16

The stage 2 limit "the host supplies the CRC5 and CRC16 bytes" is half
removed. The chip now computes and sends the data packet's CRC16. The token's
CRC5 still comes from the host and is still not checked.

One generic addition, mode field 17, `xor`: bit k of the pattern is XORed
onto bit k of a CRC-source `bits` as it is sent. USB sends its CRC inverted,
and a plain invert flag would be wrong: a sender's CRC register follows the
bits it sends, so an inverted bit feeds back and changes the bits after it.
The assembler works out the pattern whose net effect on the wire is the
inversion (`crc_send_mask`; 0x9555 for USB's CRC16). The sender's register
then ends at the same residual, 0x800D, as every listener's, so the shared
`crc_bad` check needs no exception for the sender.

The host queues the PID and the data, then RESTART where it used to queue two
CRC bytes and STOP. The old form still works, and the 14 stage 2 cases are
unchanged and pass. The program is now 48 instructions with 3 role-dependent
ones: the new `choice` on RESTART is the third, and reordering the program's
tail saved one instruction. That is exactly at both limits of the kill test.
Nothing more fits.

Three new cases (`python test_usb.py`, 17 in all):

- The reference device and the independent decoder accept the chip's CRC16.
- Over 300 random payloads of 0 to 8 bytes, the device receives the same two
  CRC bytes the reference computes.
- The line is only ever J, K or SE0, and no bit edge is late.

The adversary sweep was repeated with the chip sending the CRC: the same 139
positions, the same 31 unnoticed in the token and the PIDs, and every fault
in the data and CRC16 flagged. A wrong data bit does not reach the CRC the
chip sends, because the coder follows the bit the owner meant to send. Both
planted bugs in the new path are caught, 14 of 14 in all
(`python test_usb.py mutants`).

A full 8-byte transaction is now 14 queue entries, not 16.

### Checks after the review

- Model: 80 tests (33, 8, 16, 17 and 6), and 34 of 34 planted bugs across
  the five model sets.
- The Verilog replays 631 recorded harts tick for tick, and again with the
  prescaler at 3 and 7.
- Chip scenarios are 66 of 66 with 895 byte checks, four of them the
  transaction with the chip's CRC16. cocotb is 5 of 5.
- Planted bugs: 41 of 41 in the hart (three new: the counter wrapping, and
  two in the CRC send pattern), 23 of 23 in the chip (three new, in the
  queue), and 17 proof bugs plus the expected survivor.
- The proof passes at `dwell` 4 and fails at 3 as before, and all eight
  covers are reached.

Two planted-bug patterns had gone stale with these edits and reported that
they did not apply. Both were retargeted and are caught.

Cost: 32 flops and 1.3% area (313,360 to 317,478 um2 synthesized); the
estimated critical path goes from 6.8 to 7.0 ns. This version then passed the
Tiny Tapeout flow: layout, precheck, the gate-level test and the viewer. The
new verify workflow passed on its first run.

### The proof reaches the USB line code

The unbounded proof used to stop at what CAN needs. Its subset now also
allows ones-only stuffing, the CRC start value, residual and send pattern,
NRZI, a complementary pair on a second pin, and break bits. It runs on the
real Verilog. Only the hart's debug outputs changed, and the synthesized chip
is the same to the cell (317,478 um2, 24,057 cells).

What it now claims as well, for every program in the subset:

- Under NRZI the listener decodes exactly the bit the owner meant, from the
  change of level.
- With a pair, the second pin carries the complement at every sample point,
  and both pins are low in a break.
- The two harts hold the same violation count, so a listener never flags a
  conforming owner's break.
- Both keep the same CRC, run length and configuration, the new CRC settings
  included.

It closed after three additions to the harness. Under NRZI the sync rule
becomes "a sync bit is a 0", because only a change of level can be waited
for. Both harts hold the same sampled levels all through a bit. A break
never carries a stuff bit. `check_sync.py` now checks the first of these on
the USB program: its 2 sync bits each send a 0.

It is not vacuous. 11 new planted bugs, at least one in each new feature, all
break the proof, and so does removing the NRZI sync rule: 29 in all, plus
the one expected survivor. All 13 covers are reached, 5 of them new.

Limits, stated plainly:

- The jump a listener takes on a break (`on_break`) is outside the subset. It
  makes the two harts' control flow differ on purpose, which a lockstep proof
  cannot follow. `claim`, `choice`, `set` and traps are outside too. So the
  USB program itself is still not proven, only the line code it is built
  from.
- A program may turn the pair on but not off again, and the pair is fixed to
  pin 1.
- Under NRZI the proof relies on the line not moving between a listener's
  last sample and a sync bit. That holds inside the subset, which has no
  `set`. The USB program releases its lines with `set`, and `check_sync.py`
  does not check this half of the rule.
- The smallest bit time is still 4 ticks.

Checks: lint is clean, cocotb is 5 of 5 and the replay is 631 of 631. The
hart and chip planted-bug sets were not rerun, because outside the debug
outputs the Verilog did not change.

### One protocol proven whole: UART

The proof above covers part of the instruction set for any program, and no
complete protocol fits inside it. `rtl/uart_ind.sv` is a second unbounded
proof that goes the other way: it fixes the program and proves all of it, on
the real Verilog. The program is the one `protocols.uart()` returns.
`rtl/gen_uart_rom.py` takes its words from the assembler and stops if the
program has changed shape, so the proof cannot pass on an old copy.

It needs its own proof because `claim` puts the receiver two ticks behind the
sender on purpose. A receiver leaves `claim` only when it sees the line fall,
two ticks after the sender drove it, and stays two ticks behind to the end of
the frame. So the two harts cannot be compared tick for tick. This proof
compares the receiver with the sender as it was two ticks earlier.

**A bug found on the way.** Writing down what the proof may assume about an
undriven line exposed a start-up fault in the UART program. A hart sees a pin
two ticks after it is driven, and the first `claim` ran one tick after the
`set`. On a push-pull pin that read low before the program started, the
sender took the old level for a line in use, left the `claim` with an empty
queue and sent `0xFF`, which the receiver stored. It was reproduced in the
model and on the chip's Verilog with a pull-down on the pads: hart 1 returned
`FF A5 3C` for the two bytes sent. Loopback hid it, because an undriven line
reads high there, and the older pad scenarios hid it because they queue data
before they start the harts.

One more tick between `set` and `claim` stopped the stray byte but made the
receiver garble the first frame (`0xE9` for `0xA5`). It had only ever sampled
the line low, and a `sync` wait needs one sample of the other level before it
counts a change. The fix kept is one bit time of idle before the first frame,
`p.step("TX", A, 1, bit, free=True)`, which gives every hart a sample of the
high line. The program is now 9 instructions. It is loaded at run time, so
the chip did not change. Costs: the first frame starts one bit time later,
and for its first half bit time a receiver is not yet waiting for a start
bit.

Free in the proof, so the result holds for every choice: the bit time, from
8 to 2047 ticks; the bytes and when they arrive; the address the program is
loaded at; what the line reads while undriven, on every tick; the three
unused pins; and the contents of the 55 words outside the program.

What it claims:

- DATA. Every byte the receiver stores is the byte the sender last took from
  its queue. Takes and stores alternate, so no byte is lost, repeated or
  invented, and the sender never sends from an empty queue.
- WIRE. A monitor that sees only the wire, from the tick the sender first
  drives it, reads standard frames: a start bit low, the eight bits of the
  byte least significant first, and a stop bit high, each for exactly one bit
  time. Every start bit follows at least one bit time of high line. So the
  sender is correct for any receiver that samples inside the bit, not only
  for a Janus one.
- CLEAN. Neither hart counts a violation, loses arbitration, clears its queue
  or stores anything else, and the receiver never drives.
- LIVE. A hart rests only in boot, between instructions, in the `claim`, or
  in a bit's edge or mid state, and the last two end within one bit time. The
  receiver leaves the `claim` exactly two ticks after the start bit begins.
  The program counter stays inside the program.

It assumes that both harts leave reset on the same tick with no traps,
prescaler or adversary fault set, and that a queue entry stays until the hart
takes it.

It is not vacuous:

- 34 planted bugs each break it: 7 in the program (one takes the idle bit
  out again), 23 in the hart, 2 in the monitor's own idea of a frame, and 2
  that weaken its assumptions (a queue entry may vanish; bit times down to 4
  ticks). Two more survive, as expected. One is `sync` checking only the
  level, as in the other proof. The other loads the program past the end of
  memory: addresses wrap, so it still works, and the assembler refuses such
  a placement anyway.
- `rtl/sim_uart.sh` simulates the same harness, with every assertion and the
  monitor, on random inputs: 24 runs at bit times from 8 to 2047, 1,748
  frames over 5.3 million ticks, 14 runs starting with the line low, and a
  separate scoreboard for the bytes. No failure. The same simulation fails
  with the idle bit taken out and on a planted hart bug.

Limits, stated plainly:

- A sender and a receiver. A witness runs the receiver's path but is not in
  the proof.
- Both harts start together. A receiver that starts later or in the middle of
  a frame is not covered.
- One clock. The proof says nothing about a far end with its own clock; the
  model tests cover a sender 3% fast or slow.
- Bit times from 8 ticks. Shorter ones are not claimed.
- The queues, pin rotation and host port are outside it; the chip scenarios
  test those.
- Reachability comes from the simulation. A bounded search to the depth of
  one frame was too slow, at about 13 seconds a step.
- The other five protocols are not proven whole.

Checks on this version:

- Model: 84 tests (37, 8, 16, 17 and 6) and 35 of 35 planted bugs. The new
  tests start a sender and a receiver on a line that reads low or high, with
  the queue filled early or late.
- The Verilog replays 643 recorded harts tick for tick, and again with the
  prescaler at 3 and 7.
- Chip scenarios are 67 of 67 with 904 byte checks. The new one starts on
  pads with a pull-down and an empty queue; it fails on the old program.
  cocotb is 5 of 5.
- Planted bugs: 41 of 41 in the hart, 23 of 23 in the chip, and 29 in the
  subset proof plus its expected survivor.
- The subset proof passes at `dwell` 4 and fails at 3 as before, with all
  13 covers reached.
- Synthesis is the same to the cell (317,478 um2, 24,057 cells): only a
  debug output for the proof was added to the hart.

### The witness joins the UART proof

The UART proof had a sender and a receiver. It now runs three harts, one in
each role, so the limit "a witness is not in the proof" is gone. The witness
is the receiver in everything but its role and where its bytes go, and the
proof says exactly that: at every tick it holds the receiver's program
counter, state, bit count, received bits, bit edge and sampled levels, it
never drives, stores, takes or flags anything, and it logs each byte on the
tick the receiver stores it. So the byte the witness logs is the byte the
sender took.

The proof still closes with no new invariant about timing, but the third
hart makes it slower: about 14 minutes, was 2.

It is not vacuous: 37 planted bugs each break it, three of them new and
aimed at the witness (it logs nothing, it stores like a receiver, it samples
another pin), plus the two expected survivors. The harness simulation now has
the third hart and checks the witness's byte against the scoreboard too:
24 runs, 1,745 frames over 5.4 million ticks, 16 runs
starting with the line low, no failure.

Limits that remain: all three harts start together and share one clock, bit
times start at 8 ticks, and the other five protocols are not proven whole.

### A second protocol proven whole: SPI

`rtl/spi_ind.sv` proves the SPI program the way `uart_ind.sv` proves UART:
the real program, taken from the assembler by `rtl/gen_spi_rom.py`, on two
real harts. It covers what the UART program never uses: clocked bits, two
data lines moving at once, a byte stream with no gap between bytes, and a
trap.

The target has no clock of its own. It follows each clock edge two ticks
after the controller drives it, so the two are compared by where each stands
in the clock cycle. When CS rises, the trap sends both to `idle` on the same
tick and they are side by side again.

Free: the half period, from 8 to 2047 ticks; the four modes; the load
address; both queues; what the clock and data lines read while undriven, on
every tick; and the unwritten program words.

What it claims:

- DATA. Each side stores the byte the other sent in that slot. The controller
  never sends from an empty queue; the target sends FF when it has nothing.
- WIRE. A monitor that sees only the four wires, and knows only the textbook
  rules for the mode, reads those same bytes: most significant bit first,
  eight bits a byte, each read on the edge the mode names, with both data
  lines still across that edge. The clock moves only while CS is low, and a
  transfer is whole bytes. Without this the proof would only say that the two
  harts agree with each other.
- CLEAN. No violations. The controller alone drives CS, the clock and MOSI;
  the target alone drives MISO, and only during a transfer.
- LIVE. Each hart rests only in a short list of states, and both are back at
  `idle` together when CS has risen.

Almost all of the invariants were found by simulating the harness first and
reading the two harts' timeline off the trace. The proof then needed one
more, and closes in under two minutes.

It is not vacuous. 41 planted bugs each break it: 12 in the program, 21 in
the hart, 2 that both harts share (swapped clock phases, and least
significant bit first), 2 in the monitor's own rules and 4 that weaken its
assumptions. The two shared bugs matter most: the harts still agree with
each other under them. `rtl/sim_spi.sh` simulates the same harness on random
inputs: 52 runs in all four modes at half periods from 8 to 2047, 2,972 bytes each way in 212 transfers over 9.5 million ticks, with a separate scoreboard, and no failure.

Two findings:

- **The target drops a queued byte when a transfer ends.** It takes its next
  byte as each byte ends, before it knows whether the controller goes on. If
  the controller stops there, that byte has left the queue and is never
  sent. It happened in 106 of 212 simulated transfers. A fix needs
  the hart to take the byte only when its first bit goes out, so it is
  recorded as a limit, not fixed.
- **A bouncing CS at start-up can cut the set-up short.** The trap watches CS
  from the first tick. If an undriven CS rose before the controller drove
  it, both harts would jump to `idle` with the mode not yet written. The
  proof assumes an undriven CS holds one level, a pull-up or pull-down, and
  fails within 12 ticks when that assumption is removed.

One assumption turned out not to be needed and was removed: the target's
queue may even lose entries.

Limits: both harts start together and share one clock; half periods start at
8 ticks; no witness; the queues, pin rotation and host port are outside it.
The other four protocols are not proven whole.

### 1-Wire: a second transaction cleared the target's queue

Found while building a proof harness for the 1-Wire program, before any
invariant was written: the harness simulation showed the target losing
arbitration, which 1-Wire does not have.

When a read ends, the target moves on and waits to send the first bit of a
next byte. If the controller starts a new reset instead, the target takes the
falling edge for a read slot and drives its bit. A 1 on a line held low is
what losing arbitration looks like, and the hart acted on it: it raised the
lost flag and cleared the target's transmit queue. In the model, a target
with bytes queued for the second transaction answered `FF`.

Fix: the program now starts with `mode(lose_to=None)`. It is 30 instructions,
was 29. The chip did not change. One loss remains and is a limit, as in SPI:
the byte the target took ahead when the read ended is never sent.

Checks: a new model test runs two transactions and a planted bug that leaves
arbitration on is caught (9 tests, 5 of 5 planted bugs). The replay cannot
fill a queue twice, so that case runs on the Verilog as a chip scenario
instead, which checks the bytes and that no flag is raised. Replay 643 of 643
at prescalers 0, 3 and 7; chip scenarios 68 of 68 with 917 byte checks.

The proof came next.

### A third protocol proven whole: 1-Wire

`rtl/onewire_ind.sv` proves the 1-Wire program the way `uart_ind.sv` and
`spi_ind.sv` prove theirs: the real program, taken from the assembler by
`rtl/gen_onewire_rom.py`, on two real harts. It covers what the other two
never use: an open-drain line both sides pull low, traps on how long the line
is held, a loop counter, and a stretch where the harts are out of step.

The timings are fixed numbers of ticks, so the invariants give every counter
its exact value at every point of the program. The two harts run side by
side everywhere except in `idle` and the first 130 ticks of a reset pulse.
There the target has gone on to a next read: it takes a byte, takes the
reset pulse for a read slot, sends one bit into it and waits for a second
slot. The width trap fires in both on the same tick and they are together
again. In the tightest case the target reaches its wait on the very tick the
line falls, with nothing to spare.

Free: the load address, both queues, the three unused pins on every tick,
and the unwritten program words.

What it claims:

- DATA. The target stores the byte written. The controller stores every byte
  read, and a presence byte whose top bit is 0. It starts a transaction only
  with a byte to write and reads one byte per token. Nothing else is stored
  or taken.
- WIRE. A monitor that sees only the wire and knows only the textbook rules
  reads those same bytes, least significant bit first, from the level in the
  fifteenth tick of each slot. Every low is a slot of at most 120 ticks or a
  reset of at least 480. The presence pulse starts 15 to 60 ticks after the
  reset and lasts 60 to 240. Falls are at least 61 ticks apart.
- CLEAN. No violations, no arbitration loss, no other pin touched.
- LIVE. Each hart rests only in a short list of states.

The invariants were written from the harness simulation's trace and all held
in simulation and in the solver at the first attempt. The proof closes in 40
seconds.

It is not vacuous. 46 planted bugs each break it: 18 in the program, 16 in
the hart, 1 that both harts share (most significant bit first), 7 in the
monitor's own rules and 4 that weaken its assumptions. `rtl/sim_onewire.sh`
simulates the same harness on random inputs: 20 runs, 57 transactions, 57
bytes written and 743 read over 595,590 ticks, with a separate scoreboard,
and no failure.

What the exact numbers show:

- **The reset pulse is 482 ticks on the wire, 2 over the 480 minimum.** Each
  trap cuts the step before it short: 131 ticks to the first trap, 170 to
  the second, 181 to the release. The monitor rule fails at 483.
- **The presence pulse starts exactly 15 ticks after the reset ends,** the
  minimum, and lasts 120. The monitor rule fails at 16.
- **Falls are 70 ticks apart when writing and 64 when reading.** The monitor
  rule fails at 65.
- **The step after the first trap would let go of the line one tick after
  the second trap fires.** With the reset trap one tick later the proof
  fails.

These margins are in ticks. With a crystal clock they hold; a clock more
than 0.4 % fast would make the reset shorter than 480 microseconds. Longer
steps would widen them. The program is unchanged for now.

Limits: both harts start together and share one clock; one target; no
witness; no prescaler in the proof, so one tick is one clock; the queues,
pin rotation and host port are outside it. As in SPI, the byte the target
took ahead when a read ended is never sent. I2C, CAN and USB are not proven
whole.

### 1-Wire timing margins widened

The proof's exact numbers showed a program that met the standard with almost
nothing to spare, so a tick only slightly short would break it. The program
now has room on both sides, and the proof reads every timing from the
program's own words: `rtl/gen_onewire_rom.py` emits each step's length, and
each count in the invariants is written in terms of those lengths. The next
timing change needs no edit to the proof, and the generator checks the few
conditions the formulas take for granted.

| On the wire | Standard | Was | Now |
|---|---|---|---|
| Reset pulse | 480 or more | 482 | 522 |
| Reset end to presence pulse | 15 to 60 | 15 | 30 |
| Presence pulse | 60 to 240 | 120 | 80 |
| Controller reads presence, after the reset end | 60 to 75 | 73 | 68 |
| Reset end to first slot | 480 or more | 435 | 520 |
| Read slots, fall to fall | 61 or more | 64 | 70 |
| Reset trap before the suspect step lets go | | 0 | 31 |

The reset end to first slot was 435, short of the standard's 480. The
monitor did not check it. It now does, and on the old program that rule
fails at once in simulation. A real device has long finished its presence
pulse by 435, so nothing failed, but it was out of the standard.

The reset and the recovery after it now hold with a tick up to 7 % short.
The controller's presence read sits inside the window every device's pulse
must cover, with 8 ticks of room on one side and 7 on the other.

One timing is unchanged on purpose: a written 0 stays 60 ticks low, the
standard's minimum. One program serves both roles. In a write slot the
target follows the same steps as the controller, so a longer 0 also makes
the target later to catch the next slot. With 66 low, two model tests failed:
the target missed slots from a reference controller that runs them 70
apart, the usual timing. Measured in the
model, the target follows a master's slots of 65 ticks or more and misses
them at 64 or less. The standard allows down to 61. Both are limits of
sharing one program between the roles.

Checks: the proof closes in 39 seconds. Widening the suspect step made one
invariant too loose: it allowed states past the moment the reset trap must
fire, and induction failed until it was bounded by the hold count. 50
planted bugs each break the proof, 4 of them new: each changes one timing in
the program, word and step length together, so the proof's own formulas
follow it. A reset of 479 ticks, a first slot 479 ticks after the reset, a
presence pulse 14 ticks after it and read slots 60 apart are each caught by
the textbook rules alone. Four older planted bugs tightened a monitor rule
by one tick past the old timings, and with the wider margins they no longer
bit. They now sit one tick past the new ones: 71 ticks between falls, a
reset of 523, presence 31 ticks after the reset and under 80 long. Each
breaks the proof. The harness simulation: 20 runs, 50 transactions,
50 bytes written and 750 read over 626,058 ticks, no failure. Model tests 9
of 9.

### Fix: a byte the target took ahead was lost

The SPI and 1-Wire proofs both recorded the same limit. A target takes its
next byte before it knows it will send it: in SPI as each byte ends, before
it knows whether the controller goes on; in 1-Wire when a read ends, before
it knows whether another read slot comes. If the controller stops instead,
the byte has already left the queue and is never sent. In the SPI harness
simulation this happened in 106 of 212 transfers.

The fix is a new instruction flag, `keep`, on `load` (bit 24) and on a
clocked stream's refills (bit 12). A byte taken with it is copied but stays
at the head of the queue, and leaves as its last bit goes out. A trap, an
arbitration loss or another load before then drops the copy, and the byte
is sent next time. In the hart it is a 4-bit count of the bits still to go.
A flag and not a new rule for every load, because one load needs the old
behaviour: the 1-Wire controller takes a read token it never sends, and the
token must leave the queue at once.

The SPI program now has the target load with `keep` and the stream refill
with `keep`; the 1-Wire program has the target's read load with `keep`.

The two proofs now claim it (KEPT): a kept byte is popped exactly when its
keep count runs from 1 to 0 on a tick with no trap, the count is always the
bits of the byte still to go, and while a byte is kept it is the head of its
queue. Together: no byte leaves a queue unsent. For this they now assume
what janus_fifo already does, that the head of each queue stays until it is
popped. The SPI proof first allowed the target's queue to lose entries at
random; that freedom had to go, since a byte that vanishes on its own cannot
be kept.

Writing the SPI claim needed one more invariant: the controller's first
byte comes from an ordinary load, so it is never kept. Both proofs close.

The new count also broke the UART proof at first, though UART never uses
`keep`. The solver may start any register at any value, and nothing said the
count was 0, so a phantom kept byte could pop the queue at a random tick.
The proof now states that no hart ever holds a kept byte, and closes again.
The lockstep proof needed nothing: it leaves the pops unconnected.

One SPI planted bug survived the change: a controller that ends every
transfer after one byte. Before, only its odd queue pops gave it away. With
`keep` the unsent bytes stay queued and go out one per transfer, all
correct, and nothing the proof claimed ruled that out. It now claims what
streaming means: a transfer ends only when the controller's queue is empty.
The bug breaks the proof again.

Checks: two new model tests, an SPI case in all four modes and the 1-Wire
two-transaction test, each fail on the old model and pass on the new. The
Verilog replay compares the changed hart with the changed model tick for
tick: 643 of 643 at prescalers 0, 3 and 7. The replay fills each queue once,
so two chip scenarios run the cases that refill it: `spi_two_transfers`, and
`onewire_two_transactions`, now with a third transaction that reads the
next queued byte. 69 of 69 chip scenarios, 938 byte checks. The SPI harness
simulation now finds no byte taken ahead and dropped, in 213 transfers.
Eleven new planted bugs each break their proof: a kept byte popped at once,
popped one bit early, never popped, kept through a trap, a refill that
ignores the flag, and each program without the flag. One older SPI bug now
survives, as it should: it removes the pop from the ordinary refill, which
the SPI program no longer uses.

Cost at synthesis: 8 flip-flops, a 4-bit count in each hart, and 348 cells
in all, 0.55 % of the area (317,478 to 319,235 square micrometres). Lint
gives the same warnings as before, none of them about the new code.

### A fourth protocol proven whole: I2C

`rtl/i2c_ind.sv` proves the I2C program the way the other three proofs
prove theirs: the real program, taken from the assembler by
`rtl/gen_i2c_rom.py`, on two real harts. It covers what the others never
use: two traps that fire on one line's edge while the other line is high
(START and STOP), an address match after which a target that was not
addressed steps aside as a witness, branches on the bit just read (the R/W
bit, ACK and NACK), a choice on the head of the controller's queue between
data, STOP and RESTART, and clocked bits on open-drain lines, where the
controller lets the clock go and waits to see it rise.

Both harts read SCL on the same tick, so they run side by side almost
everywhere: in a clocked bit the target waits for the clock's edge while the
controller counts down to it. They part in two places. While the controller
sends a START from `idle`, the target is still in the claim, and the START
trap brings it along. And when the controller's queue ends a write, with a
STOP or RESTART entry or with nothing, the target does not own that choice:
it goes on into the next byte and waits there for the clock. SCL rises once
more, for the STOP or the repeated START, and the target reads that as the
byte's first bit. The trap that follows brings both harts back together,
and because the target is only at the first bit, it counts no broken byte.

Free: the half period, from 8 to 2047 ticks; the target's own address, so
it may or may not be the one sent; the load address; both queues, with data
and STOP or RESTART entries arriving at any time; the two unused pins on
every tick; and the unwritten program words.

What it claims:

- DATA. The target stores the address and every byte written, each the one
  the controller took from its queue. The controller stores every byte read:
  the one the target took, or FF when it had none. The controller takes an
  entry only to send it, or a STOP or RESTART entry that ends a write, and a
  transaction from `idle` starts only with an entry to send.
- WIRE. A monitor that sees only SCL and SDA and knows only the textbook
  rules reads those same bytes, most significant bit first. The target
  acknowledges the address only when it is its own, and then every byte
  written; the controller's acknowledge is the top bit of its queue entry. A
  START or STOP comes only between bytes and only from the controller. And
  the timing rules in the table below.
- CLEAN. No violations, no arbitration loss, no other pin touched, and the
  target never pulls SCL.
- LIVE. Each hart rests only in a short list of states, and the target is at
  the controller's word except in the two places above.

A target stores every address byte it sees, its own or not, before the
match: that is how its host learns what the bus did. A model test already
asks for it, and the proof claims it.

The invariants were written from the harness simulation's trace. The
solver's counterexamples then showed six more, each a value it was
otherwise free to choose: the target's bit count, the level a timed bit is
about to drive, the source of the bit the target waits for, the R/W bit
that chose the path, and the monitor's own copy of it. The proof closes in
16 minutes.

It is not vacuous. 48 planted bugs: 18 in the program, 17 in the hart, 1
that both harts share (least significant bit first), 8 in the monitor's own
rules and 4 that weaken its assumptions. 46 break it. Two survive, as they
should: a claim that ignores a falling line, since the target leaves `idle`
only through the START trap, which runs first; and an owner that does not
wait for a released line to rise, since nothing here holds one low. Each
bug is first simulated in the proof's own harness, and 43 fail one of its
assertions on a real run, which already means the proof cannot pass; the
solver breaks the other 3, the ones that weaken an assumption. The solver
alone took hours on some of them: a bug that needs a whole transaction to
show is past the 12 steps it checks from reset.

A fifth assumption, that the target's queue keeps its head until popped,
turned out not to be needed and was removed: the target reads the queue
only on the tick it takes the byte. `rtl/sim_i2c.sh` simulates the same harness on random
inputs, with its own scoreboard that decodes the two wires separately: 26
runs, 2,020 bytes in 920 transactions (226 writes and 124 reads
acknowledged), 693 NACKs and 86 repeated STARTs over 8.8 million ticks, no
failure.

#### Fix: the bus was free for only 4 ticks between transactions

Before writing timing invariants, the harness simulation measured each
timing rule on the wire. All of them scaled with the half period but one:
from a STOP to the next START the bus was free for 4 ticks, whatever the
half period. After a STOP the trap sent both harts to `idle`, and a
controller with an entry queued started again at once. I2C asks for the bus
to stay free at least as long as the clock's low time, 4.7 µs in standard
mode, so every device sees it idle; at a 1 µs tick, 4 ticks is 4 µs.

The program now waits a half period at `idle`, with SDA released, before it
claims the bus. It is 43 instructions, was 42; the chip did not change. A
new model test queues two writes back to back and checks the gap; it fails
on the old program. Model tests 42 of 42, replay 645 of 645, chip
scenarios 70 of 70 and cocotb 6 of 6.

| Rule | On the wire, in ticks | Proven |
|---|---|---|
| SCL low | HALF + 2 | at least HALF |
| SCL high | HALF + 1 | at least HALF |
| SDA still before SCL rises (setup) | HALF − 1 | at least HALF − 1 |
| SDA still after SCL falls (hold) | 3 | at least 2 |
| SCL high before a repeated START or a STOP | HALF | at least HALF |
| SCL high after a START | HALF + 3 | at least HALF |
| Bus free, STOP to the next START | was 4, now HALF + 3 | at least HALF |

At a 1 µs tick and HALF = 8, the smallest the proof covers, a 53 kHz clock,
every standard-mode rule now holds: SCL low 10 µs (4.7 asked), high 9
(4.0), setup 7 (0.25), START setup 8 (4.7), START hold 11 (4.0), STOP setup
8 (4.0), bus free 11 (4.7; it was 4), and a data bit is on SDA 3 µs after
SCL falls (3.45 at most).

Limits: both harts start together and share one clock; one controller and
one target, so no arbitration between controllers; no device holds SCL low,
so no clock stretching (the program waits for a stretched clock and a model
test checks it, but the proof does not cover it); no prescaler; the queues,
pin rotation and host port are outside it, though the target's queue may
even lose entries. A read always ends with the
controller's NACK and a STOP: the program has no repeated START after a
read. CAN and USB are not proven whole.

### A fifth protocol proven whole: CAN

`rtl/can_ind.sv` proves the CAN program the way the other four proofs prove
theirs: the real program, 35 words taken from the assembler by
`rtl/gen_can_rom.py`, on two real harts. Both start as possible senders. Hart
a has a queue of frames to send; hart b's queue stays empty, so it always
ends up the receiver. It covers what the others never use: a claim that
decides the role by whether the hart has a frame to send, bit stuffing sent
and checked, a CRC computed as the bits go and checked by the receiver, a
loop whose count comes from a received field, resynchronisation on falling
edges, an ACK slot the receiver drives inside the sender's frame, and a hold
trap that brings both back to `idle` after 20 recessive bit times.

The receiver is the sender two ticks late, from the middle of the start of
frame to the ACK slot: it sees the bus two ticks after the sender drives it,
and so does each step it takes. The two part around the ACK. The receiver
pulls the ACK slot low two ticks into it, as it sees the slot two ticks
late, and the sender, a listener there, moves its bit edge to that fall from
a bit time of 16 ticks on. From the ACK on, the sender runs 4 ticks late and
the receiver 2.

Free: the bit time, from 11 to 2047 ticks; the load address; hart a's queue,
with any entries arriving, changing or leaving at any time; the three unused
pins on every tick; and the unwritten program words. Assumed: both harts
leave reset together with the program's hold trap set; when hart a takes a
control field, an entry is there with RTR and IDE clear, as a host that
queues base data frames gives it; and the bus is open drain, low exactly when
a hart pulls it low.

What it claims:

- DATA. Each hart stores each field as hart a sent it: the top three bits of
  the identifier, the other eight, the control field and every data byte,
  and pushes exactly when it stores.
- WIRE. A monitor that sees only the bus and knows only the textbook rules
  for a base data frame reads a dominant start of frame, an identifier,
  dominant RTR and IDE bits, a length and as many data bytes as it asks for
  (8 at most), each byte the one hart a took, then a CRC equal to the
  monitor's own CRC-15 of the bits before it, after five equal bits always a
  stuff bit of the other value, then a recessive CRC delimiter, a dominant
  ACK slot and 11 recessive bits. Every bit lasts exactly the bit time: the
  bus changes only where a bit starts, except for the receiver's ACK, which
  starts and ends two ticks into its bits.
- CLEAN. No violations, no arbitration loss, no queue cleared, no other pin
  touched.
- LIVE. Each hart rests only in the states of timed bits and the claim, and
  between frames both wait at `idle`.

Below 11 ticks a bit is not exact: at 8 to 10 ticks the bit after the
control field runs one or two ticks long, because the six instructions
between the last control bit and the next data bit take longer than the
half bit left. 11 ticks at the chip's 25 MHz is 2.27 Mbit/s, above classic
CAN's 1 Mbit/s.

The invariants were written from the harness simulation's trace, then from
the solver's counterexamples. Most of those were values the solver was free
to choose and a real run never reaches: the monitor in its unused fourth
state, a counter past the instruction's last bit, the bus history just
before a start of frame, the monitor's CRC before the first bit. Two came
from 12-bit and 16-bit sums that wrap: at long bit times a fall a bit time
old and the idle count near 65,535 looked like small numbers. One was a real
bug, below.

The proof runs with Bitwuzla at depth 4 and closes in 9 minutes. Yices, which
the other proofs use, did not finish the same last query in 4 hours 40
minutes. Depth 4 is as sound as the 12 of the other proofs; it needs
stronger invariants, which this one has.

It is not vacuous. 36 planted bugs: 13 in the program, 13 in the hart, 1
that both harts share (least significant bit first), 5 in the monitor's own
rules and 4 that weaken its assumptions. 34 break it. Two survive, as they
should: a receiver that never finds a bad CRC, since every frame here is
good; and a wrong input lag in `sync`, which the resynchronisation right
after the start of frame corrects. 31 fail one of the harness's assertions
on a real run, which already means the proof cannot pass; the solver breaks
the other 3, which weaken an assumption. One of the hart bugs undoes the fix
below.

A fourth assumption, that an entry stays at the head of hart a's queue until
it is popped, turned out not to be needed and was removed: hart a reads its
queue only to claim the bus and on the tick it takes a byte, and a byte taken
from an empty queue is FF, which the claims follow.

`rtl/sim_can.sh` simulates the same harness on random inputs, with its own
scoreboard: 54 runs at bit times from 11 to 2047 ticks, 856 frames (107 with
fewer data bytes queued than their length asks for, sent as FF) and 7,267
fields received over 19.3 million ticks, no failure. 24 of the runs queue each
frame one to eight ticks before the hold trap would fire, at bit times 11, 16
and 49, where the bug below was.

#### Fix: the hold trap could cut off a start of frame

The proof found it. The hold trap sends both harts back to `idle` after 20
recessive bit times. A hart counts that time from the bus as it sees it, two
ticks late, so its count ran on for two ticks after it pulled the bus low
itself. If the host's frame arrived so that hart a drove its start of frame
on the tick before its count reached 20 bit times, the trap fired on the next
tick: hart a went back to `idle` with the bus still low. Both harts then
claimed the receiver role, read the start of frame and received a frame of
recessive bits, and each pushed a three-bit identifier field, 111, to its
host before a stuff error sent it to `BAD`. Hart a's frame was not lost: it
went out after the next 20 idle bits. Random tests never hit the one tick it
takes. The harness simulation now does: `+race=K` queues each frame K ticks
before the trap, and K = 5 reproduced it at bit times 11, 16 and 49.

A hart now does not count a line as held while it is itself pulling it away
from the hold level; an open-drain pin driven 1 is released, not pulled.
`janus.py` has the same rule. 1-Wire is unaffected: its traps watch for low,
and its open-drain harts never drive high. USB's idle timeout starts again
two ticks sooner when the hart drives DM itself. UART, SPI and I2C use no
hold traps. Cost: 383 um2 per hart, 0.6% (67,251 to 67,634 um2
synthesized). Model tests 42 of 42, 16 of 16 for CAN, 17 of 17 for USB, 9
of 9 for 1-Wire and 6 of 6 for the adversary; replay 645 of 645; chip
scenarios 70 of 70 with 1,028 byte checks; cocotb 6 of 6; the 1-Wire proof
passes again and its harness simulation is clean.

Laid out locally with the same flow and settings as GitHub's, the fixed chip
did not route at the old 45% density: after 33 passes of its first round the
router still had 144 violations, where a good layout clears its first round
in about a dozen, the pattern that ran GitHub's job out of time before. At
42% it routed in rounds of 15, 10, 7 and 3 passes, and at 40% in 11, 11 and
4, so `PL_TARGET_DENSITY_PCT` is now 40. No logic changed. The layout at 40%:

| | f2488cb, 45% | Hold fix, 40% |
|---|---|---|
| Utilisation | 33.2 % | 32.7 % |
| Route DRC, Magic DRC, antenna, LVS | 0, 0, 0, 0 | 0, 0, 0, 0 |
| Setup slack, slow corner, 40 ns clock | 13.34 ns | 11.42 ns |
| Hold slack | 0.121 ns | 0.104 ns |
| Max slew and max cap warnings | 30 and 1 | 40 and 0 |

The gate-level test passes 6 of 6 on its netlist.

On GitHub, at fb666c7, it then passed the full flow: layout in 1 h 55 min,
the precheck, and the gate-level test in 2 min; the next commit, c207a95,
passed it again. Two runs there failed for reasons outside the
design: that commit's first attempt lost its PDK download to a dropped
connection before synthesis began, and the gate-level job of the I2C commit
(fd26068) hung for 6 hours in `apt-get` before any test ran.

The trap can still fire on the tick before hart a would drive, which only
sends hart a back to claim again, and at hart b on the tick after, as b sees
the bus low a tick later; b then claims the receiver role on the next tick as
usual. The proof covers both.

#### Finding: an `else` after an assertion hid it from the harness simulations

In SystemVerilog, an `else` after `assert (x);` belongs to the assertion, as
what to run when it fails. Yosys reads it as the `if`'s `else`, so every
proof checked what it says. Icarus Verilog follows the standard: in the
harness simulations, an assertion written that way never reported a
failure, and the branch after it never ran. Five harnesses had it: CAN 30
times, 1-Wire 24, UART 7, I2C 5 and SPI 2. Each such assertion is now
wrapped in `begin` and `end`, which both tools read the same way; yosys
builds the same checks from the wrapped files. With every assertion live,
the UART, SPI, 1-Wire and I2C harness simulations still pass, so nothing was
hiding there. In the CAN harness the first live run caught the receiver's
trap firing one tick into a start of frame, which the claims then allowed.

The full final check on the design with both changes: planted bugs 29 of 29
in the chip and 41 of 41 in the hart, and in the proofs 29 for the subset,
37 for UART, 48 for SPI, 54 for 1-Wire, 46 for I2C and 34 for CAN, plus
their expected survivors; the UART, SPI, 1-Wire, I2C and CAN proofs pass, the
subset proof passes at `dwell` 4 and fails at 3 as before, and all 13 of its
coverage points are reached; the five harness simulations are clean. The
I2C proof took 30 minutes on a loaded machine, so the final check now gives
it an hour.

#### Two senders, in simulation

The proof keeps hart b's queue empty. `rtl/tb_can_arb.v` gives both harts a
queue. Each round queues a frame for each, the second from 6 ticks before to
6 ticks after the first, and checks that both harts store exactly the frames
that went out, the winner's when they arbitrate (the lower identifier), that
the loser's queue is cleared, and that neither counts a violation. A hart
that claims the bus before it sees the other's start of frame drives its own
up to 4 ticks later, as it sees the bus 2 ticks late and runs 4 instructions
from the claim to its start of frame; from 5 ticks apart the later one sees
the first start of frame in time and sends after it. A sender does not
resynchronise, so in arbitration the two harts' bits stay that far apart.

From a bit time of 12 ticks every skew works: `rtl/sim_can_arb.sh` makes 84
runs at bit times from 12 to 217 ticks, 1,296 rounds, 931 of them arbitrated
and 290 sent one after the other, with no failure. At 11 ticks, two starts of
frame 4 ticks apart make the earlier sender count a violation, though both
harts still store the right frames and the right hart wins. The later
sender's bits change 4 ticks into each of the earlier one's, one tick before
its sample point; which check counts the violation is not yet traced. So two
senders need a bit time of at least 12 ticks, 2.08 Mbit/s at 25 MHz.

The proof of this stage has started. `rtl/can_arb_ind.sv` runs the program on
two harts with both queues free and states the claims: the monitor reads the
winner's frame (the smaller identifier), a sender stores each field as it
took it and both harts store the same fields, only the loser loses and has
its queue cleared, and the bus changes only where the winner's bits start,
or while two still send, where either sender's do; the ACK falls in its slot
at most 6 ticks in and lasts a bit. It assumes that two frames that
arbitrate have different identifiers. `rtl/sim_can_arb_ind.sh` checks every
claim once a tick: 75 runs, every skew from 6 ticks either way and runs where
both queues refill as soon as they empty, with no failure; three claims
planted wrong are each caught. The solver's base case passes; the invariants
the induction needs are not written yet.

Limits: one sender and one receiver, so no arbitration, which is the next
stage; every frame is good, so the receiver's checks of a bad CRC, a stuff
error and a missing ACK are not covered, though model tests check them; no
error frames or retransmission, as in the program; base data frames only;
both harts start together, share one clock and see the bus with no
propagation delay; no prescaler; the queues, pin rotation and host port are
outside it. USB is not proven whole.

## Chip changes after the first green build

### Host readback for bring-up

Two things could not be checked on real silicon through the host port. The
program memory is latches written by a pulse, and nothing could read a word
back. And a hart that sent or received nothing gave no sign of where it was
waiting.

Frame `7h` answers both. It returns a hart's program counter, then its role
and state, then the instruction word it is at. The counter goes out first
and the rest is captured on that same tick, so the six bytes describe one
moment of a running hart. A stopped hart stands at its start address, so
writing the start address and reading `7h` reads the memory back one word at
a time, with no new read path into the memory: the hart's own fetch does it.
The driver has `where()` and `read_program()` for the two uses.

Cost: the hart gains two outputs and no logic. The top gains a 38-bit
capture register. On top of the `keep` fix: 1.7% area (319,235 to 324,568
um2 synthesized, 24,700 cells); the estimated critical path is unchanged, at
7.05 ns. Lint loses one warning, the hart's unconnected `pc` output, and
gains none.

Checks: a chip scenario reads a nine-word program back from address 20
through a stopped hart, then finds two running harts waiting in the `claim`,
each in its own role, before and after a byte goes through. A cocotb test
does the same through the driver. On the design with `keep`: chip scenarios
are 70 of 70 with 1,028 byte checks, cocotb is 6 of 6 and the replay is 643
of 643. Planted bugs: 29 of 29 in the chip, six of them in the new logic; 41
of 41 in the hart; 29 in the subset proof, 37 in the UART proof, 48 in the
SPI proof and 54 in the 1-Wire proof, plus their expected survivors. All
four proofs pass and the three harness simulations are clean.

Layout, run locally with the same LibreLane version, PDK and settings as the
Tiny Tapeout action, on the design with `keep` and the readback, next to the
last design without either that passed on GitHub:

| | Without (e1b7a20) | With keep and readback |
|---|---|---|
| Utilisation | 32.2 % | 33.2 % |
| Route DRC, Magic DRC, antenna | 0, 0, 0 | 0, 0, 0 |
| Setup slack, slow corner, 40 ns clock | 11.97 ns | 13.34 ns |
| Hold slack | 0.118 ns | 0.121 ns |
| Max slew and max cap warnings | 24 and 1 | 30 and 1 |

Placement differs with every change, which is why the slack moved the other
way; both are far from failing.

Limits: the memory can be read only through a stopped hart. A word that was
never written reads as whatever its latches hold.

### Layout time on GitHub

The `keep` commit passed every check but its layout did not finish: GitHub
stopped the job at its 6-hour limit. An earlier commit, 440ab7c, had been
stopped the same way. The job logs show where the time goes. Detailed
routing routes the whole design, adds antenna diodes where a wire needs one,
and routes again, up to three more times. Each round repeats passes until no
violation is left. Most layouts get there in a few passes; some keep a
violation or two the router cannot clear and spend hours on it:

| Layout | Passes in each round | Detailed routing on GitHub |
|---|---|---|
| e1b7a20, before `keep` | 9, 8, 6, 4 | 36 min |
| chip-v2, readback before `keep` | 39, 44, 13 | 224 min |
| b380833, `keep` | 60 and more, 1 violation left for 5 hours | stopped at 6 hours |
| f2488cb, `keep` and readback | 14, 9, 7, 4 | whole layout job 119 min |

The routing is deterministic. A local run on a 24-core machine gives the
same violation counts as the GitHub run on 4 cores in every pass that can be
compared, so a local layout shows before a push whether GitHub will finish.
Which layout gets stuck is not predictable from the change: `keep`, 8
flip-flops, led to a stuck spot, and adding the readback on top took it out
again. Every chip change is now laid out locally first.

The combined design then passed the whole flow on GitHub: layout in 119
minutes, precheck and the gate-level test.
