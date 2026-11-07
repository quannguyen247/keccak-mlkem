# Keccak SHA3/SHAKE FPGA core for ML-KEM

This repository contains synthesizable Verilog RTL for Keccak-f[1600] and the
four FIPS 202 functions used by ML-KEM: SHAKE128, SHAKE256, SHA3-256 and
SHA3-512. The core computes one permutation round per clock cycle and keeps a
single 1600-bit state shared by the permutation and the sponge. Padding is done
in hardware. Bus wrappers connect the core either to an AMD AXI DMA on the Kria
KV260 (AXI4-Lite CSR and AXI4-Stream) or to Altera mSGDMA on the DE1-SoC
(Avalon-MM CSR and Avalon-ST).

The core is a building block for a later ML-KEM accelerator. It does not
implement ML-KEM KeyGen, Encaps or Decaps.

## Key results

The standalone run of `keccak_top_wrapper` uses AMD Vivado
2025.2.1 on Artix-7 `xc7a75tfgg676-3` at 250 MHz (4 ns clock period), with
default synthesis and implementation strategies and no debug cores:

- Resources: 7,138 LUTs (all logic), 3,266 flip-flops, 0 BRAM, 0 DSP.
- Timing: WNS = +0.111 ns, WHS = +0.091 ns, no failing endpoints. The
  estimated Fmax from WNS is 1000 / (4.000 - 0.111), about 257 MHz.
- Latency: 24 cycles per permutation. A single-block SHA3-256 request takes
  26 cycles from `start` to the digest. Dependent message blocks are absorbed
  every 25 cycles and SHAKE output blocks follow every 26 cycles.
- Throughput: SHA3-256 over 16 KiB takes 3,026 cycles, or 8.66 Gbit/s at
  200 MHz, in RTL simulation.

The KV260 designs include the Zynq PS, the DMA, interconnect and, in one
build, a System ILA. Their resource figures belong to a different device and
context and are listed separately in the [implementation results](docs/RESULT.md).

## Source layout

| Path | Purpose |
| --- | --- |
| [`rtl/`](rtl/) | Core RTL (`modules/`) and shared headers (`utils/`) |
| [`testbench/`](testbench/) | Self-checking testbenches for the core and the SoC wrapper |
| [`vector/`](vector/) | `keccak_vector.py`, the golden-vector generator shared by both testbenches |
| [`constraint/`](constraint/) | 4 ns clock constraint for the standalone build |
| [`project/keccak_top/`](project/keccak_top/) | Xilinx Vivado project (Artix-7) for standalone `keccak_top_wrapper` |
| [`project/keccak_soc/`](project/keccak_soc/) | Xilinx Vivado KV260 block design without debug cores; includes simulation-only AXI protocol checker IPs used by `keccak_soc_tb.v` |
| [`project/keccak_soc_ila/`](project/keccak_soc_ila/) | Xilinx Vivado KV260 block design with a System ILA and the same simulation checkers; its XSA feeds the Vitis platform |
| [`project/ip_repo/keccak_core/`](project/ip_repo/keccak_core/) | Packaged Xilinx IP `quannguyen247.org:user:keccak_core:1.0` |
| [`project/software/`](project/software/) | **Xilinx software** — AMD Vitis 2025.2 workspace (`keccak_platform` and the `keccak_test` bare-metal application for KV260) |
| [`project/keccak_altera/`](project/keccak_altera/) | Intel/Altera Quartus Prime 23.1 & Platform Designer (`system.qsys`) Cyclone V SoC project |
| [`project/keccak_altera/software/`](project/keccak_altera/software/) | **Altera software** — Nios II Software Build Tools for Eclipse projects (`keccak_altera` application and `keccak_altera_bsp`) |
| [`docs/SPEC.md`](docs/SPEC.md) | IP technical specification and CSR map |
| [`docs/RESULT.md`](docs/RESULT.md) | Synthesis and implementation results |

> **Software directories note:**
> - [`project/software/`](project/software/) is the **Xilinx** software workspace (AMD Vitis 2025.2 targeting Zynq UltraScale+ on Kria KV260).
> - [`project/keccak_altera/software/`](project/keccak_altera/software/) is the **Altera** software workspace (Nios II Software Build Tools for Eclipse targeting the Cyclone V Platform Designer system).

| RTL module | Role |
| --- | --- |
| `keccak_permutation.v` | Keccak-f[1600], one round per cycle |
| `keccak_sponge.v` | Absorb and squeeze FSM for the four modes |
| `keccak_pad_block.v` | Combinational FIPS 202 padding |
| `keccak_top.v` | Native core: padding and sponge |
| `keccak_top_wrapper.v` | AXI4-Lite CSR and AXI4-Stream ports for Xilinx AXI DMA |
| `keccak_top_wrapper_avalon.v` | Avalon-MM CSR and Avalon-ST ports for Altera mSGDMA |

Generated synthesis/implementation run directories, Quartus databases and
software build outputs are not tracked. Rebuild them after changing RTL,
constraints or software.
The Vivado SoC projects include their block designs, IP configurations and
checker simulation manifests, and the Quartus project includes `system.qsys`
and `system.sopcinfo`, so all project files can be opened directly from a fresh
clone. Vivado 2025.2.1 and Quartus Prime 23.1 regenerate IP outputs locally on
first compile.

## Test and build

The repository includes 150 test vectors, so both testbenches can run after a
fresh clone. The testbenches find the vector files relative to their own path.
To regenerate the default set or choose a different number of cases from the
repository root:

```sh
python3 vector/keccak_vector.py 150
```

The core testbench runs in Icarus Verilog from the repository root:

```sh
iverilog -g2012 -I rtl/utils -o keccak_top.vvp testbench/keccak_top_tb.v rtl/modules/keccak_pad_block.v rtl/modules/keccak_permutation.v rtl/modules/keccak_sponge.v rtl/modules/keccak_top.v
vvp -n keccak_top.vvp
```

The SoC testbench instantiates AMD AXI and AXI4-Stream protocol checker IPs on
the wrapper ports, so it runs in the Vivado simulator: open
`project/keccak_soc/keccak_soc.xpr` and run behavioral simulation with
`keccak_soc_tb` as the top. A protocol violation appears as an `ERROR` line in
the simulator log. Setting `FAULT_CASE` in the testbench to a case index injects
a deliberate `TDATA` change under backpressure to show that the checker fires;
the default `-1` turns it off.

Both runs print a pass count and write a per-case log to
`testbench/keccak_top_result.log` and `testbench/keccak_soc_result.log`. The
current RTL passes 150/150 cases in each, with no checker errors.

For Xilinx standalone implementation, open `project/keccak_top/keccak_top.xpr`
in Vivado 2025.2.1 and run synthesis and implementation. For the KV260 board,
build `project/keccak_soc_ila/keccak_soc_ila.xpr`, export hardware with the
bitstream, open `project/software` in Vitis 2025.2.1, update `keccak_platform`
if needed, and build/run `keccak_test` (`TEST_MODE` in
`project/software/keccak_test/src/main.c` selects the function).

For Altera, open `project/keccak_altera/keccak_altera.qpf` in Quartus Prime
23.1 to compile the hardware design, and import `keccak_altera_bsp` and
`keccak_altera` from `project/keccak_altera/software/` into Nios II Software
Build Tools for Eclipse to build and run the firmware.

Simulation checks the core against Python `hashlib` with directed boundary
cases and random messages. It does not cover the wrapper error paths, and it
does not establish throughput on the board, where DMA, DDR and software costs
have not been measured.

## Documentation

- [IP technical specification](docs/SPEC.md): interfaces, microarchitecture,
  CSR map, error codes, KV260 and DE1-SoC integration, performance and
  verification.
- [Implementation results](docs/RESULT.md): standalone and KV260 resource and
  timing results.

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
