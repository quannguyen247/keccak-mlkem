package require -exact qsys 13.0
set_module_property NAME stream_byte_order_adapter
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "Avalon-ST byte-lane wiring"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property ELABORATION_CALLBACK elaborate
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH
set_fileset_property QUARTUS_SYNTH TOP_LEVEL stream_byte_order_adapter
add_fileset_file stream_byte_order_adapter.v VERILOG PATH stream_byte_order_adapter.v TOP_LEVEL_FILE
add_parameter DATA_WIDTH INTEGER 64
set_parameter_property DATA_WIDTH HDL_PARAMETER true
set_parameter_property DATA_WIDTH ALLOWED_RANGES {32 64}
set_parameter_property DATA_WIDTH AFFECTS_ELABORATION true
add_parameter INPUT_HIGH_FIRST BOOLEAN true
set_parameter_property INPUT_HIGH_FIRST HDL_PARAMETER false
set_parameter_property INPUT_HIGH_FIRST AFFECTS_ELABORATION true
add_interface clock clock end
add_interface_port clock clk clk Input 1
add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset_n reset_n Input 1
add_interface in avalon_streaming sink
add_interface out avalon_streaming source
foreach name {in out} {
    set_interface_property $name associatedClock clock
    set_interface_property $name associatedReset reset
    set_interface_property $name dataBitsPerSymbol 8
    set_interface_property $name emptyWithinPacket false
    set_interface_property $name readyLatency 0
    set_interface_property $name maxChannel 0
}
proc elaborate {} {
    set width [get_parameter_value DATA_WIDTH]
    set high [get_parameter_value INPUT_HIGH_FIRST]
    set empty_width [expr {$width == 64 ? 3 : 2}]
    set_interface_property in firstSymbolInHighOrderBits $high
    set_interface_property out firstSymbolInHighOrderBits [expr {!$high}]
    foreach name {in out} {
        set_interface_property $name symbolsPerBeat [expr {$width / 8}]
    }
    foreach {name direction ready_direction} {in Input Output out Output Input} {
        add_interface_port $name ${name}_data data $direction $width
        add_interface_port $name ${name}_empty empty $direction $empty_width
        add_interface_port $name ${name}_valid valid $direction 1
        add_interface_port $name ${name}_ready ready $ready_direction 1
        add_interface_port $name ${name}_startofpacket startofpacket $direction 1
        add_interface_port $name ${name}_endofpacket endofpacket $direction 1
    }
}
