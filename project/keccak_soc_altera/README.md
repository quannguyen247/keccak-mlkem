# DE1-SoC Keccak system

Open `keccak_soc_altera.qpf` with Quartus Prime Lite 23.1std.1 (Cyclone V device support). The top `keccak_soc_altera.v` instantiates the Platform Designer system in `system.qsys`: Nios II/e, JTAG UART, 64 KiB on-chip memory, two mSGDMA channels, byte-order adapters and the shared Avalon Keccak IP.

Run Analysis & Synthesis from this directory:

```sh
quartus_map --read_settings_files=on --write_settings_files=off keccak_soc_altera -c keccak_soc_altera
```

Quartus regenerates the Qsys HDL under its local database from `system.qsys` and the two local `*_hw.tcl` component descriptors. A pre-existing `system/` or `db/` directory is not required.

`debug/keccak_soc_altera.stp` is the retained Signal Tap source; its QSF node assignments are also preserved. Generated Signal Tap files in `db/` are not source inputs. The Qsys clock and physical board clock are 50 MHz; the checked-in SDC uses the existing 100 MHz comparison target. No PLL changes the physical clock.

The Nios II application and BSP are preserved as `software/keccak_soc_altera` and `software/keccak_soc_altera_bsp`. Their Eclipse project names, ELF name and BSP references match these directories. Firmware is loaded separately over JTAG; on-chip memory initialization is disabled in Qsys, so an ELF or HEX file is not needed for synthesis.

See [Altera build and source audit](../../docs/ALTERA_BUILD.md) for the file selection and validation scope.
