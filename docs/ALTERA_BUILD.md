# Altera projects: build and source audit

The two projects target Cyclone V `5CSEMA5F31C6`. Validation used Quartus Prime Lite 23.1std.1, Build 993, with Cyclone V device support installed.

| Project directory | Synthesis top | Debug |
| --- | --- | --- |
| `project/keccak_top_altera` | `keccak_top_wrapper_avalon` | Signal Tap disabled |
| `project/keccak_soc_altera` | `keccak_soc_altera` | Signal Tap retained |

## Build from a clean clone

Put the installed Quartus `bin` directory on `PATH`, then run:

```sh
git clone --branch dev --single-branch https://github.com/quannguyen247/keccak-mlkem.git
cd keccak-mlkem
(cd project/keccak_top_altera && quartus_map --read_settings_files=on --write_settings_files=off keccak_top_altera -c keccak_top_altera)
(cd project/keccak_soc_altera && quartus_map --read_settings_files=on --write_settings_files=off keccak_soc_altera -c keccak_soc_altera)
```

These commands run Analysis & Synthesis. The GUI equivalent is to open the corresponding QPF and select **Processing > Start > Start Analysis & Synthesis**.

Quartus automatically generates the SoC IP from `system.qsys` into `db/ip/system/`. Neither generated HDL nor a previously populated database is required. The local component descriptors resolve shared RTL through relative paths. An ELF/HEX file is unnecessary: Qsys has on-chip memory initialization disabled.

## Files selected for version control

| Input | Reason for inclusion |
| --- | --- |
| Standalone QPF, QSF and SDC | Project revision, device, synthesis top, shared source list and clock constraint |
| Shared `rtl/modules/` and `rtl/utils/` | Existing Keccak core, Avalon wrapper and included definitions/functions; reused directly |
| SoC QPF, QSF, SDC, top-level Verilog and assignment-defaults QDF | Existing project settings, board ports and system instance; revision and top renamed together |
| `system.qsys` | Platform Designer source: Nios II/e, JTAG UART, 64 KiB memory, TX/RX mSGDMA and Keccak connections |
| `keccak_core_hw.tcl`, `stream_byte_order_adapter_hw.tcl`, `stream_byte_order_adapter.v` | Local component discovery and the byte-lane wiring required by Qsys |
| `debug/keccak_soc_altera.stp` and QSF Signal Tap assignments | Existing SoC probes, triggers and instrumentation configuration |
| `system.sopcinfo` and `software/` | Preserved Nios II application/BSP and hardware handoff; optional for synthesis |
| Project READMEs and ignore rules | Reproduction instructions and exclusion of generated state |

The SoC retains all 172 previously tracked files under the new paths, plus its README. The application directory, Eclipse project names, ELF target and BSP references use `keccak_soc_altera` / `keccak_soc_altera_bsp`. The standalone directory contains five source/configuration files: QPF, QSF, SDC, README and .gitignore.

The source audit inventoried and hashed all 1,089 previously tracked files. All 914 tracked files outside the old Altera directory and the three edited root documentation/ignore files were unchanged. Eight packaged Xilinx RTL/testbench copies were checked against their canonical shared files and matched byte for byte. The review covered the shared RTL, wrappers, testbenches, project source references, hardware integration and application entry points; existing vendor BSP libraries were preserved.

The QSF keeps 512 assignments referencing `auto_signaltap_0`. Removing these can produce a successful synthesis without the expected analyzer. The obsolete `SLD_FILE db/stp3_auto_stripped.stp` reference was removed; that generated database file is not needed to reconstruct the analyzer. The STP source now lives outside `output_files/`.

Databases, generated Qsys HDL, fitter/programming outputs, reports, QWS/Eclipse workspace state, object/ELF files and backups are excluded. Previously ignored helper scripts targeting a different Cyclone II/SRAM design are excluded as well. No new build helper or dependency was added.

## Validation record (2026-11-11)

| Analysis & Synthesis | Errors | Warnings |
| --- | ---: | ---: |
| `keccak_top_altera` | 0 | 4 |
| `keccak_soc_altera` | 0 | 448 |

Both commands were checked from a clean clone containing only committed files, with no copied databases or generated HDL. Quartus reports success in `output_files/<revision>.map.rpt` and `output_files/<revision>.map.summary`.

The SoC log reports message 35024: `auto_signaltap_0` connects all **485** required debug inputs/clocks/pins. Its synthesis log also lists the `sld_signaltap:auto_signaltap_0` partition. This checks that the retained debug configuration actually instantiates the analyzer.

Warnings remain. The standalone project reports a constant `avs_waitrequest` output and an unused `asi_startofpacket` input. SoC warnings include Nios II deprecation, generated interconnect width truncation/unused signals and connectivity or optimized-away-node messages. These runs establish successful source reconstruction and synthesis; they do not establish timing closure, firmware execution or board behavior.

The physical SoC clock and Qsys clock are 50 MHz. Its existing SDC comparison target is 100 MHz; no PLL changes the physical clock. The standalone SDC also targets 100 MHz and covers internal clock timing, with reset excluded and external I/O timing unspecified. Synthesis resource counts are not fitted ALM utilization.
