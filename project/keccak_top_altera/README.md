# Standalone Keccak IP for Cyclone V

Open `keccak_top_altera.qpf` with Quartus Prime Lite 23.1std.1 (Cyclone V device support). The synthesis top is `keccak_top_wrapper_avalon`, using the shared RTL in `../../rtl/` and a 64-bit stream.

Run Analysis & Synthesis from this directory:

```sh
quartus_map --read_settings_files=on --write_settings_files=off keccak_top_altera -c keccak_top_altera
```

The SDC targets 100 MHz for internal IP timing. External I/O timing is unspecified and reset is excluded. Signal Tap is disabled. Databases and generated outputs stay local.

See [Altera build and source audit](../../docs/ALTERA_BUILD.md) for clean-clone validation and the SoC project.
