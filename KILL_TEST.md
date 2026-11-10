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
