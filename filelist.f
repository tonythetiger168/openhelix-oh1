# OpenHelix OH-1 v0.1 filelist（編譯順序有意義）
rtl/oh1_pkg.sv
rtl/oh1_decode.sv
rtl/oh1_core.sv
tb/oh1_if.sv
tb/oh1_seq_lib.sv      # 須在 agent 之前（driver 使用 oh1_prog_item）
tb/oh1_agent.sv
tb/oh1_scoreboard.sv
tb/oh1_env.sv
tb/oh1_tests.sv
tb/tb_top.sv
