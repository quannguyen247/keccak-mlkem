# Keccak SHA3/SHAKE hardware IP technical specification

## Overview

This document specifies the `keccak_top` core and its SoC wrapper
`keccak_top_wrapper`. The core computes the Keccak-f[1600] permutation and the
four FIPS 202 functions that ML-KEM (FIPS 203) uses: SHAKE128, SHAKE256,
SHA3-256 and SHA3-512. It is written in Verilog-2001 and uses only slice logic
on the reported Artix-7 build.

The section layout follows the
[OpenTitan IP documentation guide](https://opentitan.org/book/doc/contributing/doc/example_ip_block.html).
This is a documentation convention only. The IP does not use the OpenTitan bus
(TL-UL) and has none of its security countermeasures.

### Features

- One Keccak-f[1600] round per clock cycle, 24 cycles per permutation, with a
  single 1600-bit state register shared by the permutation and the sponge.
- Runtime selection of SHAKE128, SHAKE256, SHA3-256 or SHA3-512 through a 2-bit
  mode input.
- FIPS 202 padding (domain suffix and `pad10*1`) inside the core, so the caller
  sends raw message bytes.
- Finite or open-ended SHAKE output.
- An AXI4-Lite register slave with AXI4-Stream input and output for use with
  an AMD AXI DMA. Stream width is 32 or 64 bits.
- No Block RAM and no DSP in either the core or the wrapper.

### Scope and limitations

The IP is a building block for a later ML-KEM accelerator. It does not
implement ML-KEM KeyGen, Encaps or Decaps, and it is not a NIST-validated
cryptographic module. The design has no masking, no hiding and no fault
detection. No side-channel resistance is claimed.

## Functions and data conventions

| `mode` | Function | Rate (bytes) | Capacity (bits) | Suffix | Output |
| ---: | --- | ---: | ---: | :---: | --- |
| `0` | SHAKE128 | 168 | 256 | `0x1F` | Any length of at least 1 byte |
| `1` | SHAKE256 | 136 | 512 | `0x1F` | Any length of at least 1 byte |
| `2` | SHA3-256 | 136 | 512 | `0x06` | 32 bytes |
| `3` | SHA3-512 | 72 | 1024 | `0x06` | 64 bytes |

The 1600-bit state holds 25 lanes of 64 bits. Lane `i = x + 5*y` occupies
`state[64*i +: 64]`. Byte `k` of a message block, of a squeeze block and of an
AXI4-Stream word sits at bits `[8*k +: 8]`, so byte 0 is always in the least
significant position.

The padding unit appends the suffix byte right after the last message byte and
sets bit 7 of the last rate byte. If the suffix and the final bit land in the
same byte (message length `rate - 1`), that byte becomes `0x9F` for SHAKE or
`0x86` for SHA3. A message whose length is an exact multiple of the rate needs
one more block that holds only padding. An empty message is one padded block.

## Native core interface (`keccak_top`)

All ports are declared in
[`keccak_top.v`](../rtl/modules/keccak_top.v). The core has one clock
and a synchronous active-low reset.

| Signal | Dir | Width | Description |
| --- | :---: | ---: | --- |
| `clk` | in | 1 | Clock, rising edge. |
| `rst_n` | in | 1 | Synchronous active-low reset. Returns the FSMs to idle and clears the state. |
| `mode` | in | 2 | Function select, sampled with `start`. |
| `start` | in | 1 | Starts a request. Accepted only while the core is idle. |
| `output_blocks` | in | 32 | SHAKE output length in rate blocks, sampled with `start`. `0` selects open-ended output. Ignored for SHA3. |
| `absorb_valid` | in | 1 | Input block valid. |
| `absorb_ready` | out | 1 | Core can accept an input block. |
| `absorb_last` | in | 1 | Marks the final input block of the request. |
| `msg_block_in` | in | 1344 | Raw message block, byte 0 in bits `[7:0]`. |
| `msg_len_bytes` | in | 8 | Valid bytes in `msg_block_in`. |
| `squeeze_valid` | out | 1 | Output block valid. |
| `squeeze_ready` | in | 1 | Caller accepts the output block. |
| `squeeze_last` | in | 1 | Ends an open-ended SHAKE stream on the accepted block. |
| `squeeze_out` | out | 1344 | Output block. Bytes beyond `squeeze_bytes` read as zero. |
| `squeeze_bytes` | out | 8 | Valid bytes per output block: 168, 136, 32 or 64. |
| `done` | out | 1 | One-cycle pulse after the final output block is accepted. |

### Operation protocol

1. Drive `mode` and `output_blocks`, then pulse `start` for one cycle while the
   core is idle.
2. Send the message in rate-sized blocks. Each block is transferred when
   `absorb_valid` and `absorb_ready` are both high. Every block except the last
   has `msg_len_bytes` equal to the rate.
3. Send the final block with `msg_len_bytes` below the rate and `absorb_last`
   high. If the message length is a multiple of the rate, the final block is
   empty (`msg_len_bytes = 0`). Hold `msg_block_in`, `msg_len_bytes` and
   `absorb_last` until the block is accepted.
4. Read output blocks on `squeeze_valid && squeeze_ready`. Lowering
   `squeeze_ready` stalls the core with the block held stable. SHA3 produces
   one block. SHAKE produces `output_blocks` blocks, or with
   `output_blocks = 0` it continues until a block is accepted with
   `squeeze_last` high. The caller discards unused bytes of the final SHAKE
   block.
5. `done` pulses for one cycle and the core returns to idle.

`absorb_last` and `squeeze_last` have an effect only in the cycle their
handshake completes.

## Microarchitecture

### Permutation (`keccak_permutation.v`)

[`keccak_permutation.v`](../rtl/modules/keccak_permutation.v) computes theta,
rho, pi, chi and iota as one combinational round and writes the result back to
the state register. A 5-bit counter selects the round constant, and
`last_round` is high in the cycle that writes round 23. When idle, a request
XORs `xor_in` into the state and starts round 0 in the next cycle. The state
register is also `state_out`, and the core keeps no other copy of the state.
There is no pipeline register inside the round, so the core works on one
message at a time.

### Sponge (`keccak_sponge.v`)

[`keccak_sponge.v`](../rtl/modules/keccak_sponge.v) runs a one-hot FSM with the
states IDLE, ABSORB, START, PERMUTE, SQUEEZE and DONE. On an accepted block it
XORs the rate part of the padded block into the permutation state and runs one
permutation. The absorb mask is built from three fixed slices (576, 1088 and
1344 bits), so the capacity is never written. After the final permutation the
rate part of the state goes to `squeeze_out` through a mode-dependent mask, and
capacity bits never reach the output. For each further SHAKE block the FSM
spends one START cycle and one permutation.

The sponge drives the permutation's `clear` input while idle, so the state is
zeroed the cycle after a request finishes and stays zero until the next
request.

### Padding (`keccak_pad_block.v`)

[`keccak_pad_block.v`](../rtl/modules/keccak_pad_block.v) is combinational. It
copies the first `msg_len_bytes` bytes, writes the suffix at byte
`msg_len_bytes` and sets the final bit of the rate. Bytes past the message
length are replaced by padding, so the caller does not have to clear them.
`keccak_top` uses only the first padded block; the module's second-block
outputs are left unconnected because the caller sends the extra padding block
itself.

## SoC wrapper (`keccak_top_wrapper`)

[`keccak_top_wrapper.v`](../rtl/modules/keccak_top_wrapper.v) packages the
core for a Zynq SoC. It holds the AXI4-Lite registers, a 1344-bit block buffer
and a stream FSM (IDLE, START, INPUT, ABSORB, OUTPUT, FINISH, RECOVER). The
packaged IP is `quannguyen247.org:user:keccak_core:1.0` in
[`project/ip_repo/keccak_core`](../project/ip_repo/keccak_core).

| Parameter | Default | Description |
| --- | ---: | --- |
| `AXIS_DATA_WIDTH` | 64 | Stream width in bits. Supported values are 32 and 64. The KV260 design uses 64. |

All interfaces use `aclk` and the synchronous active-low reset `aresetn`.

| Interface | Type | Description |
| --- | --- | --- |
| `s_axi_ctrl` | AXI4-Lite slave | 32-bit data, 12-bit byte address, registers below. |
| `s_axis_dma` | AXI4-Stream slave | Message input from DMA MM2S: `TDATA`, `TKEEP`, `TVALID`, `TREADY`, `TLAST`. |
| `m_axis_dma` | AXI4-Stream master | Digest or XOF output to DMA S2MM, same signals. |
| `irq` | Level output | High while `IRQ_ENABLE` is set and `DONE` or `ERROR` is set. |

### Data path

After START the wrapper copies `MODE`, `MESSAGE_BYTES` and the output length
into run registers, so later register writes do not affect the running
request. Input words are stored into the block buffer at the current byte
offset. When the buffer holds a full rate block, or the beat that ends the
message arrives, the buffer is passed to the core. `TREADY` is high only in the
INPUT state, so the DMA waits while the core permutes. An empty message skips
the input phase and absorbs one padding block.

The first output word comes straight from `squeeze_out`. In the same cycle the
wrapper copies the whole block into the block buffer and serializes the rest
from there, which lets the core compute the next SHAKE block in parallel.
`TKEEP` marks a partial final word and `TLAST` marks the final output byte.
Output stays stable while `TVALID` is high and `TREADY` is low. `DONE` is set
after the final output beat is accepted and the core has finished.

### AXI4-Lite behavior

- Write: AW is accepted when no write is open and no B response is pending.
  W is accepted only after AW. One write is outstanding at a time and B is
  registered.
- Read: AR is accepted while RVALID is low. R is registered and held under
  backpressure.
- Responses: an unaligned address returns SLVERR, an address above `0x14`
  returns DECERR, and a write to `STATUS` or `VERSION` returns SLVERR. A write
  with a non-OKAY response changes nothing. `AWPROT` and `ARPROT` are ignored.

### Register map

Offsets are relative to the base address set in the block design
(`0xA0010000` in the KV260 design).

| Offset | Name | Access | Description |
| ---: | --- | :---: | --- |
| `0x00` | `CONTROL` | RW / W1P | Bit 0 `START`, bit 1 `SOFT_RESET`, bit 2 `CLEAR_STATUS`: self-clearing strobes that need `WSTRB[0]`. Bit 8 `IRQ_ENABLE`: read/write, needs `WSTRB[1]`. |
| `0x04` | `STATUS` | RO | Bit 0 `BUSY`, bit 1 `DONE` (sticky), bit 2 `ERROR` (sticky), bit 5 `IRQ`, bits 15:8 error code. |
| `0x08` | `MODE` | RW | Bits 1:0 select the function. Needs `WSTRB[0]`. Resets to `1` (SHAKE256). |
| `0x0C` | `MESSAGE_BYTES` | RW | Message length in bytes. Byte-strobed. |
| `0x10` | `OUTPUT_BYTES` | RW | SHAKE output length in bytes. Byte-strobed. Ignored for SHA3. |
| `0x14` | `VERSION` | RO | `0x4B534C31` (ASCII `KSL1`). |
| `0x18`-`0xFFC` | reserved | | DECERR, read data zero. |

`CONTROL` reads back only `IRQ_ENABLE`. When `SOFT_RESET` and `START` are
written together, only the reset takes effect. `SOFT_RESET` returns the stream
FSM and the core to idle and clears `DONE`, `ERROR` and the error code. The
configuration registers keep their values. `CLEAR_STATUS` clears the sticky
flags without touching the core, and a legal `START` clears them as well.

`SOFT_RESET` and the RECOVER reset are registered: they take effect one cycle
after the `CONTROL` write (or after entering RECOVER). The extra cycle keeps the
AXI4-Lite decode off the enables of the 1344-bit block buffer and the reset of
the 1600-bit state. Software cannot observe the delay, because the next AXI4-Lite write needs at
least two more cycles.

SHA3-256 and SHA3-512 use an output length of 32 and 64 bytes set in hardware.
`OUTPUT_BYTES` still reads back the written value. `BUSY` is high from START
until the request finishes, and during the cycle that reports a stream error.

### Error codes

| Code | Cause | Effect on a running request |
| ---: | --- | --- |
| `0x01` | `START` while busy | None. The running request continues. |
| `0x02` | `START` with an output length of zero | None. No request starts. |
| `0x03` | `TKEEP` empty or not contiguous from lane 0, or a partial beat before the end of the message | Aborted |
| `0x04` | `TLAST` before `MESSAGE_BYTES` is reached | Aborted |
| `0x05` | Beat reaches `MESSAGE_BYTES` without `TLAST` | Aborted |
| `0x06` | Beat carries more bytes than remain in the message | Aborted |
| `0x07` | Stream FSM in an illegal state | Aborted |

A stream error drops the offending beat, resets the core one cycle after
RECOVER and returns the wrapper to idle with `TREADY` low. The rest of
the MM2S transfer then stalls inside the DMA, so software must reset the DMA
channels before the next request.

## KV260 integration

`Implementation/project/keccak_soc` (without debug cores) and
`Implementation/project/keccak_soc_ila` (with a System ILA) contain the block
design `keccak_system` for the Kria KV260 (`xck26-sfvc784-2LV-c`):

- Zynq UltraScale+ PS: `M_AXI_HPM0_FPD` for register access, `S_AXI_HP0_FPD`
  for DMA traffic, PL clock 0 at 200 MHz.
- AXI DMA 7.1 in simple mode (no scatter-gather), 64-bit memory and stream
  width, data realignment on both channels, MM2S burst length 16, 26-bit
  transfer length. Register base `0xA0000000`.
- `keccak_core_0` with `AXIS_DATA_WIDTH = 64`. MM2S feeds `s_axis_dma` and
  `m_axis_dma` feeds S2MM. Register base `0xA0010000`.
- An interrupt concat with three inputs to PS IRQ0.
- In `keccak_soc_ila` only: a System ILA with 8192 samples and three interface
  monitor slots.

The 26-bit DMA length limits a single transfer, and therefore `MESSAGE_BYTES`
and `OUTPUT_BYTES`, to `2^26 - 1` bytes in this design.

### Software sequence

[`Software/keccak_test/src/main.c`](../../Software/keccak_test/src/main.c)
uses this sequence:

1. Write `CONTROL.SOFT_RESET` (`0x2`).
2. Flush the input and output buffers from the data cache.
3. Submit the S2MM transfer with the output length (32 or 64 for SHA3).
4. Submit the MM2S transfer with the message length. The DMA waits because
   `TREADY` stays low until the wrapper starts.
5. Write `MODE`, `MESSAGE_BYTES` and `OUTPUT_BYTES`, then
   `CONTROL = 0x101` (`START` with `IRQ_ENABLE`).
6. Poll until `STATUS` shows `DONE = 1` and `BUSY = 0` and both DMA channels
   are idle. `DONE` means the last beat left the IP; the S2MM idle bit means
   the data reached memory.
7. Invalidate the output buffer in the data cache and read the result.

On `ERROR`, a DMA error or a timeout, write `SOFT_RESET | CLEAR_STATUS`, reset
both DMA channels and discard the partial output before the next request. An
empty message has no MM2S transfer. `IRQ_ENABLE` needs `WSTRB[1]`, so a CONTROL
write that keeps interrupts on must keep bit 8 set.

## Performance

For `I` absorbed blocks (including the padding block) and `O` output blocks,
the core runs `I + O - 1` permutations. SHA3 has `O = 1`, and SHAKE has
`O = ceil(output_bytes / rate)`.

Cycle counts of `keccak_top` with an always-ready output, measured in RTL
simulation:

| Quantity | Cycles |
| --- | ---: |
| Permutation | 24 |
| Single-block request, `start` to first output block | 26 |
| Single-block request, `start` to `done` | 27 |
| Interval between dependent absorbed blocks | 25 |
| Interval between SHAKE output blocks | 26 |
| SHA3-256 over 16 KiB (121 blocks), `start` to output | 3,026 |

At 200 MHz the absorb ceiling is `rate_bits * 200 MHz / 25`: 8.70 Gbit/s for
SHA3-256 and SHAKE256, 10.75 Gbit/s for SHAKE128 and 4.61 Gbit/s for SHA3-512.
The SHAKE output ceiling is `rate_bits * 200 MHz / 26`: 10.34 Gbit/s for
SHAKE128 and 8.37 Gbit/s for SHAKE256. The 16 KiB SHA3-256 request reaches
8.66 Gbit/s.

With a 64-bit stream, a 136-byte block takes 17 beats, fewer than the 25-cycle
absorb interval, so the wrapper stays limited by the core when the DMA keeps
up. A 32-bit stream needs 34 beats per 136-byte block and becomes the limit.
DMA, DDR and software overheads have not been measured on the board.

## Implementation results

Standalone IP, `Implementation/project/keccak_top`: top `keccak_top_wrapper`,
out-of-context, Artix-7 `xc7a75tfgg676-3`, 4 ns clock
([`keccak.xdc`](../constraint/keccak.xdc)), Vivado 2025.2.1 default synthesis
and implementation strategies.

| LUT | FF | BRAM | DSP | WNS | WHS | Failing endpoints |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 7,668 | 3,279 | 0 | 0 | +0.022 ns | +0.091 ns | 0 |

All LUTs are logic LUTs; there is no LUTRAM or SRL. The design uses 256 F7 and
128 F8 muxes. From the routed WNS the estimated Fmax is
`1000 / (4.000 - 0.022)`, about 251 MHz.

Full KV260 designs at 200 MHz, with the PS, DMA, interconnect and, in the ILA
build, debug cores:

| Project | CLB LUT | CLB FF | BRAM tiles | WNS | WHS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `keccak_soc` | 12,713 | 11,973 | 3 | +0.289 ns | +0.010 ns |
| `keccak_soc_ila` | 16,258 | 18,028 | 62 | +0.358 ns | +0.010 ns |

These numbers describe whole systems on a different device family and are not
comparable with the standalone core result.

## Verification

[`keccak_vector.py`](../vector/keccak_vector.py) writes the test vectors with
Python `hashlib` as the reference. Both testbenches read the same files,
`vector/keccak_tv.mem` and `vector/keccak_tv_spec.txt`. Each line of the
`.mem` file holds one case: expected output (400 bytes), message (400 bytes),
output length (16 bits), message length (16 bits) and mode (8 bits).

The directed cases cover, for every mode, the message `"abc"`, message lengths
0 to 9 bytes around the 8-byte stream beat, and lengths `rate - 1`, `rate`,
`rate + 1` and `2*rate + 3`. The SHAKE modes also get output lengths of 1, 7,
9, `rate`, `rate + 1` and `2*rate + 7` bytes. That gives 72 directed cases. The
remaining cases are random, from a fixed xorshift32 seed (`0x1A2B3C4D`), with
messages of 0 to 400 bytes and outputs of 1 to 400 bytes.

| Testbench | Device under test | Stimulus | Result (150 cases) |
| --- | --- | --- | --- |
| [`keccak_top_tb.v`](../testbench/keccak_top_tb.v) | `keccak_top` | Random gaps before `absorb_valid`; `squeeze_ready` low about one cycle in four | 150/150 pass |
| [`keccak_soc_tb.v`](../testbench/keccak_soc_tb.v) | `keccak_top_wrapper`, 64-bit stream | AXI4-Lite register access, random gaps between input beats, output `TREADY` low about one cycle in four, AXI protocol checkers on all three interfaces | 150/150 pass |

The `keccak_top_tb.v` result was obtained with Icarus Verilog and the
`keccak_soc_tb.v` result with the Vivado simulator. The Vivado projects use the
same testbenches as simulation tops.

### Protocol checkers

`keccak_soc_tb.v` instantiates three AMD protocol checker IPs that monitor the
wrapper ports:

| Instance | IP | Monitors | Configuration |
| --- | --- | --- | --- |
| `u_pc_axi` | `axi_protocol_checker_0` (AXI Protocol Checker) | `s_axi_ctrl` | AXI4-Lite, 32-bit data, 12-bit address |
| `u_pc_in` | `axis_protocol_checker_0` (AXI4-Stream Protocol Checker) | `s_axis_dma` | 8-byte `TDATA`, `TKEEP`, `TLAST`, `TREADY` |
| `u_pc_out` | `axis_protocol_checker_0` | `m_axis_dma` | Same as `u_pc_in` |

Both SoC projects include the IPs for simulation only. They are not in the
block design, so they do not change the synthesis or implementation results.
Wait-limit checks (`MAX_*_WAITS`) are disabled. `pc_status` and `pc_asserted`
are left unconnected: a violation is printed as an `ERROR` line in the
simulator log and is not part of the testbench pass count. The testbench needs
a simulator that can compile the generated AMD checker models; it has also
been run with QuestaSim.

The local parameter `FAULT_CASE` (default `-1`, off) selects one case for
fault injection. In that case the testbench forces `s_axis_dma_tready` low for
four cycles and flips bit 0 of `TDATA` while `TVALID` is high. `u_pc_in` then
reports `AXI4STREAM_ERRM_TDATA_STABLE`, and the case also fails its digest
check because the wrapper absorbs the changed word. With `FAULT_CASE = 9` the
run ends at 149/150, which shows that the checker is active.

The testbenches do not drive the error paths (codes `0x01` to `0x07`),
`SOFT_RESET` during a request, or the interrupt. There is no UVM environment,
formal proof, coverage closure, gate-level simulation, side-channel evaluation
or fault-injection campaign. On the board, `main.c` hashes `"abc"` in the mode
selected by `TEST_MODE` and compares the result with a reference string.

## Reset and security notes

`aresetn` resets the whole wrapper and the core. The sponge zeroes the
permutation state while idle, so no state survives a finished request. The
wrapper's block buffer is not cleared and keeps the last input block or output
block until the next request overwrites it. The core does not erase buffers in
external memory; software must clear message and result buffers when they are
no longer needed.

Production use needs a separate review of bitstream and JTAG access, DMA
isolation, cache sharing, zeroization, side channels and fault attacks.

## References

1. National Institute of Standards and Technology, *SHA-3 Standard:
   Permutation-Based Hash and Extendable-Output Functions*, FIPS 202, Aug.
   2015. DOI: [10.6028/NIST.FIPS.202](https://doi.org/10.6028/NIST.FIPS.202).
2. National Institute of Standards and Technology, *Module-Lattice-Based
   Key-Encapsulation Mechanism Standard*, FIPS 203, Aug. 2024. DOI:
   [10.6028/NIST.FIPS.203](https://doi.org/10.6028/NIST.FIPS.203).
3. AMD, *AXI DMA LogiCORE IP Product Guide*, PG021. [Online]. Available:
   <https://docs.amd.com/r/en-US/pg021_axi_dma>.
4. OpenTitan Project, "Example IP Block Guide," *OpenTitan Documentation*.
   [Online]. Available:
   <https://opentitan.org/book/doc/contributing/doc/example_ip_block.html>.
