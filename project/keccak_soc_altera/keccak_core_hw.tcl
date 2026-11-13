package require -exact qsys 13.0

set_module_property NAME keccak_core
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "Keccak SHA3/SHAKE (Avalon)"
set_module_property DESCRIPTION "Avalon-MM registers and Avalon-ST input/output for keccak_top_wrapper_avalon"
set_module_property AUTHOR quannguyen247
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property ELABORATION_CALLBACK elaborate

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH
set_fileset_property QUARTUS_SYNTH TOP_LEVEL keccak_top_wrapper_avalon
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false
add_fileset_file keccak_top_wrapper_avalon.v VERILOG PATH ../../rtl/modules/keccak_top_wrapper_avalon.v TOP_LEVEL_FILE
foreach name {keccak_top keccak_sponge keccak_permutation keccak_pad_block} {
    add_fileset_file ${name}.v VERILOG PATH ../../rtl/modules/${name}.v
}
foreach name {keccak_defs keccak_funcs} {
    add_fileset_file ${name}.vh VERILOG_INCLUDE PATH ../../rtl/utils/${name}.vh
}

add_parameter AXIS_DATA_WIDTH INTEGER 64
set_parameter_property AXIS_DATA_WIDTH HDL_PARAMETER true
set_parameter_property AXIS_DATA_WIDTH ALLOWED_RANGES {32 64}
set_parameter_property AXIS_DATA_WIDTH AFFECTS_ELABORATION true

add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock aclk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset aresetn reset_n Input 1

add_interface csr avalon end
set_interface_property csr associatedClock clock
set_interface_property csr associatedReset reset
set_interface_property csr addressUnits SYMBOLS
set_interface_property csr bitsPerSymbol 8
set_interface_property csr readLatency 0
set_interface_property csr readWaitTime 0
set_interface_property csr writeWaitTime 0
set_interface_property csr setupTime 0
set_interface_property csr holdTime 0
set_interface_property csr maximumPendingReadTransactions 0
add_interface_port csr avs_address address Input 12
add_interface_port csr avs_read read Input 1
add_interface_port csr avs_write write Input 1
add_interface_port csr avs_writedata writedata Input 32
add_interface_port csr avs_byteenable byteenable Input 4
add_interface_port csr avs_readdata readdata Output 32
add_interface_port csr avs_waitrequest waitrequest Output 1

add_interface stream_in avalon_streaming end
add_interface stream_out avalon_streaming start
foreach name {stream_in stream_out} {
    set_interface_property $name associatedClock clock
    set_interface_property $name associatedReset reset
    set_interface_property $name dataBitsPerSymbol 8
    set_interface_property $name firstSymbolInHighOrderBits false
    set_interface_property $name emptyWithinPacket false
    set_interface_property $name readyLatency 0
    set_interface_property $name maxChannel 0
}

add_interface interrupt interrupt sender
set_interface_property interrupt associatedClock clock
set_interface_property interrupt associatedReset reset
set_interface_property interrupt associatedAddressablePoint csr
set_interface_property interrupt irqScheme NONE
add_interface_port interrupt irq irq Output 1

proc elaborate {} {
    set width [get_parameter_value AXIS_DATA_WIDTH]
    set symbols [expr {$width / 8}]
    set empty_width [expr {$width == 64 ? 3 : 2}]
    set_interface_property stream_in symbolsPerBeat $symbols
    set_interface_property stream_out symbolsPerBeat $symbols
    add_interface_port stream_in asi_data data Input $width
    add_interface_port stream_in asi_empty empty Input $empty_width
    add_interface_port stream_in asi_valid valid Input 1
    add_interface_port stream_in asi_ready ready Output 1
    add_interface_port stream_in asi_startofpacket startofpacket Input 1
    add_interface_port stream_in asi_endofpacket endofpacket Input 1
    add_interface_port stream_out aso_data data Output $width
    add_interface_port stream_out aso_empty empty Output $empty_width
    add_interface_port stream_out aso_valid valid Output 1
    add_interface_port stream_out aso_ready ready Input 1
    add_interface_port stream_out aso_startofpacket startofpacket Output 1
    add_interface_port stream_out aso_endofpacket endofpacket Output 1
}