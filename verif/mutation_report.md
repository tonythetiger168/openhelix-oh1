# Mutation sanity check

| Mutant | File | Result | First detection |
|---|---|---|---|
| M1 SLTU compares signed | oh1_core.sv | killed | `84890.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 8329] wb_data[0]: dut=0x1 model=0x0` |
| M2 branch taken if ANY active lane agrees | oh1_core.sv | killed | `31010.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 2941] exec_pc: dut=0x1c0c model=0x1c04` |
| M3 stack-full check off by one | oh1_core.sv | killed | `1060950.01ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 1733] core_stk_ovf: dut=0x0 model=0x1` |
| M4 masked-off lanes also store | oh1_core.sv | killed | `30560.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 2896] dmem_wmask: dut=0xf model=0x2` |
| M5 vdot4 drops the accumulator | oh1_core.sv | killed | `8320.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 672] wb_data[0]: dut=0x0 model=0xffffffe3` |
| M6 IRQ_STAT write-1-to-clear inverted | oh1_axi_lite.sv | killed | `8930.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 733] irq: dut=0x1 model=0x0` |
| M7 imem writable while busy | oh1_axi_lite.sv | killed | `8380.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 678] bresp: dut=0x0 model=0x2` |
| M8 STATUS.done not masked by busy | oh1_axi_lite.sv | killed | `720.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 73] rdata: dut=0x5 model=0x4` |
| M9 SRAI decoded as SRLI | oh1_decode.sv | killed | `424240.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 12636] wb_data[0]: dut=0x7ffff model=0xffffffff` |
| M10 JALR divergence not flagged | oh1_core.sv | killed | `587320.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 3774] core_illegal: dut=0x0 model=0x1` |
| M11 TMC argument masked by lane 0's active bit | oh1_core.sv | killed | `79720.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(226) [uvm_test_top.env.sb]: [cyc 7812] exec_mask: dut=0x0 model=0xf` |
| M12 SYNC fetch-ahead ignores the LW stall | oh1_core.sv | killed | `[710000] %Error: oh1_core_sva.sv:222: Assertion failed in oh1_tb_top.u_core.u_core_sva.g_sync.a_fetch_next: 'assert' failed.` |
