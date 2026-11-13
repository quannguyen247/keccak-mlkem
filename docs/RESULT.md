# Keccak SHA3/SHAKE hardware IP implementation results

This document lists the synthesis and implementation results of the IP
specified in [SPEC.md](SPEC.md).

Standalone IP: the Vivado project is `project/keccak_top`,
and its synthesis top is `keccak_top_wrapper`, which instantiates the native
`keccak_top` core. The results include the wrapper. The build uses
Artix-7 `xc7a75tfgg676-3`, a 4 ns clock
([`keccak.xdc`](../constraint/keccak.xdc)), and Vivado 2025.2.1 default
synthesis and implementation strategies.

| LUT | FF | BRAM | DSP | WNS | WHS | Failing endpoints |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 7,138 | 3,266 | 0 | 0 | +0.111 ns | +0.091 ns | 0 |

Resource counts are taken from the routed design. The run's
`utilization_placed` report (7,133 LUTs, 3,263 FFs) is written before the
post-place `phys_opt_design` step, which replicates a few cells for timing.

All LUTs are logic LUTs; there is no LUTRAM or SRL. The design uses 256 F7 and
128 F8 muxes. From the routed WNS the estimated Fmax is
`1000 / (4.000 - 0.111)`, about 257 MHz.

For comparison, Dolmeta et al. [4] report 9,651 LUTs and 8,697 FFs for their
whole SHA-3 architecture, and 6,841 LUTs and 4,279 FFs for its SHA3 core
alone (the values in parentheses in their Table II). Their Artix-7 XC7A75-3
result is reported at 250 MHz. The standalone result above includes the AXI
wrapper, so its resource boundary differs from the paper's SHA3 core.

Full KV260 designs at 200 MHz, with the PS, DMA, interconnect and, in the ILA
build, debug cores:

| Project | CLB LUT | CLB FF | BRAM tiles | WNS | WHS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `keccak_soc` | 12,753 | 11,931 | 3 | +0.646 ns | +0.010 ns |
| `keccak_soc_ila` | 16,291 | 17,983 | 62 | +0.297 ns | +0.010 ns |

These numbers describe whole systems on a different device family and are not
comparable with the standalone wrapper result.

## References

4. A. Dolmeta, M. Martina and G. Masera, "Hardware architecture for
   CRYSTALS-Kyber post-quantum cryptographic SHA-3 primitives," *PRIME*, 2023,
   pp. 209-212. DOI:
   [10.1109/PRIME58259.2023.10161780](https://doi.org/10.1109/PRIME58259.2023.10161780).
