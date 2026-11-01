# Mutation sanity check

| Mutant | File | Result | First detection |
|---|---|---|---|
| M1 SLTU compares signed | oh1_core.sv | killed | `38230.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 3663] wb_data[3]: dut=0x0 model=0x1` |
| M2 branch taken if ANY active lane agrees | oh1_core.sv | killed | `45650.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 4405] exec_pc: dut=0x2c model=0x1c` |
| M3 stack-full check off by one | oh1_core.sv | killed | `[495410000] %Error: oh1_core_sva.sv:90: Assertion failed in oh1_tb_top.u_core.u_core_sva.a_stk_bound: 'assert' failed.` |
| M4 masked-off lanes also store | oh1_core.sv | killed | `30730.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 2913] dmem_wmask: dut=0xf model=0x8` |
| M5 vdot4 drops the accumulator | oh1_core.sv | killed | `41320.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 3972] wb_data[0]: dut=0x0 model=0x26` |
| M6 IRQ_STAT write-1-to-clear inverted | oh1_axi_lite.sv | killed | `10450.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 885] irq: dut=0x0 model=0x1` |
| M7 imem writable while busy | oh1_axi_lite.sv | killed | `10140.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 854] bresp: dut=0x0 model=0x2` |
| M8 STATUS.done not masked by busy | oh1_axi_lite.sv | killed | `720.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 73] rdata: dut=0x5 model=0x4` |
| M9 SRAI decoded as SRLI | oh1_decode.sv | killed | `195260.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 19366] wb_data[1]: dut=0x1 model=0xffffffff` |
| M10 JALR divergence not flagged | oh1_core.sv | killed | `534360.00ns ERROR    ..lix-oh1/verif/tb/oh1_env.py(220) [uvm_test_top.env.sb]: [cyc 3774] core_illegal: dut=0x0 model=0x1` |
