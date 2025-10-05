reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

open_hw; connect_hw_server
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device [current_hw_device]
program_hw_devices -force <new-bit>/arty_secure_jtag_axi_demo_core.bit