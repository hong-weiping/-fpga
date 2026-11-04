# Lesson 5: actual clocks in the lesson 3/4 design.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]

# Extra implementation margin on the 100MHz SD/FAT32 domain.
# This tightens the requirement; it does not relax or exclude data paths.
set_clock_uncertainty -setup 0.400 [get_clocks {sd_card_clk}]

# Pixel and serial clocks run concurrently, with real data transfers.
# Do NOT declare them exclusive or false-path all inter-clock transfers.
# External reset assertion is asynchronous; local reset recovery/removal
# and synchronizer stage 1 -> stage 2 paths remain timed.

# No fabricated board I/O delays or blanket FIFO/SDRAM clock exceptions.
# Add endpoint-specific CDC/I/O constraints after inspecting mapped pins and
# the board/card timing specification. Other clocks retain default uncertainty.

# Raw reset requests feed reset_sync only; they are asynchronous by design.
# Keep all local release -> functional-register checks, and all data checks.
set_false_path -through [get_nets {ext_rst_n audio_source_reset_raw audio_fifo_reset_raw u_write_cdc/rst}]
# u_write_cdc/rst feeds only the FIFO's asynchronous local-release chains.

# dht_snapshot_cdc uses a bundled-data request/acknowledge handshake.
# Only asynchronous crossings are excluded. req_meta->req_sync and
# ack_meta->ack_sync remain timed; held_data is stable before ack is observed.
set_false_path -through [get_nets {u_dht_snapshot/request u_dht_snapshot/ack u_dht_snapshot/held_data*}]
set_false_path -through [get_nets {u_mqtt_snapshot/request u_mqtt_snapshot/ack u_mqtt_snapshot/held_data*}]

# Rejection memory freezes before synchronized ready is released; no writes thereafter.
set_false_path -through [get_nets {u_mqtt_raw/u_info/request u_mqtt_raw/u_info/ack u_mqtt_raw/u_info/held_data* u_mqtt_raw/buffer*}]

# Volume snapshots use the same bundled-data request/acknowledge CDC.
# Synchronizer stage-to-stage and all synchronous logic remain timed.
set_false_path -through [get_nets {u_volume_to_audio/request u_volume_to_audio/ack u_volume_to_audio/held_data*}]
set_false_path -through [get_nets {u_volume_applied/request u_volume_applied/ack u_volume_applied/held_data*}]

# Bundled notice state crosses only through request/acknowledge snapshots.
set_false_path -through [get_nets {u_notice_to_video/request u_notice_to_video/ack u_notice_to_video/held_data*}]
set_false_path -through [get_nets {u_notice_applied/request u_notice_applied/ack u_notice_applied/held_data*}]

# Verified dht_snapshot_cdc instances: held_data remains unchanged throughout
# two-stage ACK synchronization and destination capture. Stage-to-stage paths stay timed.
set_false_path -through [get_nets {u_brightness_cdc/request u_brightness_cdc/ack u_brightness_cdc/held_data*}]
set_false_path -through [get_nets {u_brightness_uart/request u_brightness_uart/ack u_brightness_uart/held_data*}]
set_false_path -through [get_nets {u_control_reply_cdc/request u_control_reply_cdc/ack u_control_reply_cdc/held_data*}]

# Only the asynchronous input of the verified two-flop noise synchronizer.
# s1 -> s2 and all downstream alarm processing remain timed.
set_false_path -through [get_nets {noise_cdc_launch}]

# Coherent seven-segment number snapshot; no bitwise bus CDC.
set_false_path -through [get_nets {u_number_snapshot/request u_number_snapshot/ack u_number_snapshot/held_data*}]

# Additional audited instances of the same held-data handshake.
set_false_path -through [get_nets {u_control_request_cdc/request u_control_request_cdc/ack u_control_request_cdc/held_data*}]
set_false_path -through [get_nets {u_environment_cdc/request u_environment_cdc/ack u_environment_cdc/held_data*}]
# fifo_reset now reaches only async reset-release chains, never memory data enables.
set_false_path -through [get_nets {u_reader/fifo_reset}]

# wav_end is consumed only by u_audio_end_sd first-stage sampler.
# Keep the sampler stage-to-stage path timed even if mapping packs it with control logic.
set_false_path -through [get_nets {audio_end_cdc_launch}]
