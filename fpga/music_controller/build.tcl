# Final-source rebuild entry; no archived verification projects required.
set project_dir [file dirname [file normalize [info script]]]
open_project [file join $project_dir music_controller.gprj]
set_option -top_module control_ui_v24_top
set_option -output_base_name music_controller
# Retain the qualified physical implementation options.
set_option -include_path [list [file join $project_dir src practice]]
set_option -opt_goal area
# Shift registers have a separate mapper from RAM arrays (SUG1220 3.5).
# Small pixel delay pipelines must not consume four under-filled BSRAMs.
set_option -shift_reg registers
set_option -map_option 2
# Preserve clocks and packing; no seed sweep or timing relaxation.
set_option -place_option 2
set_option -route_option 2
# Controlled routing fanout, not another seed or placer algorithm.
set_option -route_maxfan 23
set_option -use_cpu_as_gpio 1
# Rebuild using the same synthesis and physical implementation settings.
run syn
run pnr
