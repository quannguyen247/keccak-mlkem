# Keccak SHA3/SHAKE FPGA core for ML-KEM

This repository contains synthesizable Verilog RTL for Keccak-f[1600] and the
four FIPS 202 functions used by ML-KEM: SHAKE128, SHAKE256, SHA3-256 and
SHA3-512. The core computes one permutation round per clock cycle and keeps a
single 1600-bit state shared by the permutation and the sponge. Padding is done
in hardware. An AXI4-Lite and AXI4-Stream wrapper connects the core to an AMD
AXI DMA on the Kria KV260.

The core is a building block for a later ML-KEM accelerator. It does not
implement ML-KEM KeyGen, Encaps or Decaps.

## Key results

The standalone out-of-context run uses AMD Vivado 2025.2.1 on Artix-7
`xc7a100tcsg324-1` at 200 MHz (5 ns clock period), with default synthesis and
implementation strategies and no debug cores:

- Resources: 5,868 LUTs (all logic), 1,675 flip-flops, 0 BRAM, 0 DSP.
- Timing: WNS = +0.125 ns, WHS = +0.104 ns, no failing endpoints. The
  estimated Fmax from WNS is 1000 / (5.000 - 0.125), about 205 MHz.
- Latency: 24 cycles per permutation. A single-block SHA3-256 request takes
  26 cycles from `start` to the digest. Dependent message blocks are absorbed
  every 25 cycles and SHAKE output blocks follow every 26 cycles.
- Throughput: SHA3-256 over 16 KiB takes 3,026 cycles, or 8.66 Gbit/s at
  200 MHz, in RTL simulation.
- Power: Vivado estimates 0.577 W total on-chip power (0.491 W dynamic,
  0.085 W static) with default vectorless switching activity. This is an
  estimate, not a board measurement.

The KV260 designs include the Zynq PS, the DMA, interconnect and, in one
build, a System ILA. Their resource figures belong to a different device and
context and are listed separately in the [specification](Implementation/docs/SPEC.md#implementation-results).

## Source layout

| Path | Purpose |
| --- | --- |
| [`Implementation/rtl/`](Implementation/rtl/) | Core RTL (`modules/`) and shared headers (`utils/`) |
| [`Implementation/testbench/`](Implementation/testbench/) | Self-checking testbenches for the core and the SoC wrapper |
| [`Implementation/vector/`](Implementation/vector/) | `keccak_vector.py`, the golden-vector generator shared by both testbenches |
| [`Implementation/constraint/`](Implementation/constraint/) | 5 ns clock constraint for the standalone build |
| [`Implementation/project/keccak_ip/`](Implementation/project/keccak_ip/) | Artix-7 out-of-context project for `keccak_top` |
| [`Implementation/project/keccak_soc/`](Implementation/project/keccak_soc/) | KV260 block design without debug cores |
| [`Implementation/project/keccak_soc_ila/`](Implementation/project/keccak_soc_ila/) | KV260 block design with a System ILA; its XSA feeds the Vitis platform |
| [`Implementation/project/ip_repo/keccak_core/`](Implementation/project/ip_repo/keccak_core/) | Packaged IP `quannguyen247.org:user:keccak_core:1.0` |
| [`Implementation/docs/SPEC.md`](Implementation/docs/SPEC.md) | IP technical specification and register map |
| [`Software/`](Software/) | Vitis 2025.2 workspace: KV260 platform and the `keccak_test` bare-metal app |

| RTL module | Role |
| --- | --- |
| `keccak_permutation.v` | Keccak-f[1600], one round per cycle |
| `keccak_sponge.v` | Absorb and squeeze FSM for the four modes |
| `keccak_pad_block.v` | Combinational FIPS 202 padding |
| `keccak_top.v` | Native core: padding and sponge |
| `keccak_top_wrapper.v` | AXI4-Lite registers and AXI4-Stream ports for DMA use |

Vivado run directories, generated vectors and Vitis build output are not
tracked. Rebuild them after changing RTL, constraints or software.

## Test and build

Generate the vectors, then run both testbenches from the `Implementation`
directory. The testbenches find the vector files relative to their own path,
so the working directory matters.

```sh
cd Implementation
python3 vector/keccak_vector.py 150
```

```sh
iverilog -g2012 -I rtl/utils -o keccak_ip.vvp testbench/keccak_ip_tb.v rtl/modules/*.v
vvp -n keccak_ip.vvp
```

```sh
iverilog -g2012 -I rtl/utils -o keccak_soc.vvp testbench/keccak_soc_tb.v rtl/modules/*.v
vvp -n keccak_soc.vvp
```

Both runs print a pass count and write a per-case log to
`testbench/keccak_ip_result.log` and `testbench/keccak_soc_result.log`. The
current RTL passes 150/150 cases in each. The same testbenches are the
simulation tops in the Vivado projects.

For implementation, open `Implementation/project/keccak_ip/keccak_ip.xpr` in
Vivado 2025.2.1 and run synthesis and implementation. For the board, build
`keccak_soc_ila`, export the hardware with the bitstream, update the Vitis
platform in `Software/keccak_platform`, and run `keccak_test`. Set `TEST_MODE`
in `Software/keccak_test/src/main.c` to choose the function. The program
hashes `"abc"` through the DMA and prints `PASS` or `FAIL` over UART.

Simulation checks the core against Python `hashlib` with directed boundary
cases and random messages. It does not cover the wrapper error paths, and it
does not establish throughput on the board, where DMA, DDR and software costs
have not been measured.

## Documentation

- [IP technical specification](Implementation/docs/SPEC.md): interfaces,
  microarchitecture, register map, error codes, KV260 integration, performance
  and verification.

## References

1. National Institute of Standards and Technology, *SHA-3 Standard:
   Permutation-Based Hash and Extendable-Output Functions*, FIPS 202, Aug.
   2015. DOI: [10.6028/NIST.FIPS.202](https://doi.org/10.6028/NIST.FIPS.202).
2. National Institute of Standards and Technology, *Module-Lattice-Based
   Key-Encapsulation Mechanism Standard*, FIPS 203, Aug. 2024. DOI:
   [10.6028/NIST.FIPS.203](https://doi.org/10.6028/NIST.FIPS.203).

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE)
for details.
