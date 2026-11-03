set root [file dirname [file normalize [info script]]]
open_project [file join $root gesture_vision.gprj]
set_option -top_module p20_crop_live_top
set_option -output_base_name gesture_vision
set_option -use_sspi_as_gpio 1
set_option -max_fanout 128
set_option -place_option 2
set_option -route_option 2
set_option -timing_driven 1
run all
exit
