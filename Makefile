# OpenHelix OH-1 RTL 驗證 Makefile
# 用法: make sim SIM=vcs|xrun|questa TEST=<test_name> [SEED=<n>]

SIM     ?= vcs
TEST    ?= oh1_rand_test
SEED    ?= 1
RUN_DIR := sim/run_$(TEST)_$(SIM)_$(SEED)

FLIST := filelist.f

VCS_OPTS    := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
               +incdir+tb -f $(FLIST) -debug_access+all -l $(RUN_DIR)/compile.log
XRUN_OPTS   := -uvmhome CDNS-1.2 -sv -timescale 1ns/1ps -f $(FLIST) \
               -incdir tb -access +rwc -logfile $(RUN_DIR)/compile.log
QUESTA_OPTS := -sv -timescale 1ns/1ps +incdir+tb -f $(FLIST) \
               -l $(RUN_DIR)/compile.log

# 覆蓋率開關：make sim SIM=vcs COV=1（line/toggle/fsm/cond/assert 由工具收集；
# 功能覆蓋由 TB 內 covergroup / cover property 自動收集）
COV ?= 0
ifeq ($(COV),1)
VCS_OPTS += -cm line+tgl+fsm+cond+assert
SIMV_COV := -cm line+tgl+fsm+cond+assert -cm_name $(TEST)_$(SEED)
endif

.PHONY: sim cov lint lint-verilator lint-yosys tools-check clean

# ---- 開源工具鏈（使用者空間，見 tools/manifest.txt）----
# 使用: source tools/env.sh 後 make lint
lint: lint-verilator lint-yosys

lint-verilator:
	verilator --lint-only -sv -Wall rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv --top-module oh1_core

lint-yosys:
	yosys -p "read_verilog -sv rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv; hierarchy -top oh1_core; proc; check" -l sim/yosys.log

tools-check:
	iverilog -V 2>&1 | head -1
	yosys -V
	verilator --version

# ---- Verilator smoke（M0.2 閉環標準流程）----
# 用 --binary 內建 main：不再經 sim/verilator_main.cpp（該自訂 main 與
# verilator 5.052 --timing 組合會零輸出靜默結束，已確認 --binary 正常）
# 建置戰術：/dev/shm 建置（避開 /mnt FUSE 的 EAGAIN/空檔問題）→ cp 回 sim/bin 執行
# （/dev/shm 為 noexec 且容器重開機會清空；sim/bin 為持久化交付物）
SMOKE_BIN := sim/bin/Vtb_smoke
SIMD_BIN  := sim/bin/Vtb_simd
RAND_BIN  := sim/bin/Vtb_rand

smoke: $(SMOKE_BIN)
	$(SMOKE_BIN)

$(SMOKE_BIN): rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv tb/tb_smoke.sv | sim/bin
	rm -rf /dev/shm/obj_smoke
	verilator --binary --timing -j 4 -Wno-fatal -Wno-TIMESCALEMOD \
	  rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv tb/tb_smoke.sv \
	  --top-module tb_smoke -Mdir /dev/shm/obj_smoke -o Vtb_smoke
	cp /dev/shm/obj_smoke/Vtb_smoke $@
	rm -rf /dev/shm/obj_smoke

# SIMD engine 定向驗證：逐 lane RF/dmem 期望值檢查（ALU/LSU/TMC/分歧）
simd: $(SIMD_BIN)
	$(SIMD_BIN)

$(SIMD_BIN): rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv tb/tb_simd.sv | sim/bin
	rm -rf /dev/shm/obj_simd
	verilator --binary --timing -j 4 -Wno-fatal -Wno-TIMESCALEMOD \
	  rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv tb/tb_simd.sv \
	  --top-module tb_simd -Mdir /dev/shm/obj_simd -o Vtb_simd
	cp /dev/shm/obj_simd/Vtb_simd $@
	rm -rf /dev/shm/obj_simd

# Random ISA generator ＋ golden model co-verification（standalone CRV，無需 VCS）
# 用法：make rand [SEED=7] [N_PROG=50]
rand: $(RAND_BIN)
	$(RAND_BIN) +seed=$(or $(SEED),1) +n_prog=$(or $(N_PROG),20)

# AXI4-Lite wrapper 驗證（W2）
axi:
	verilator --binary --timing -j 4 -Wno-fatal -Wno-TIMESCALEMOD \
	  rtl/oh1_axi_lite.sv tb/tb_axi_smoke.sv \
	  --top-module tb_axi_smoke -Mdir /dev/shm/obj_axi -o Vtb_axi
	./sim/bin/Vtb_axi 2>/dev/null || cp /dev/shm/obj_axi/Vtb_axi sim/bin/ && ./sim/bin/Vtb_axi

$(RAND_BIN): rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv tb/tb_rand.sv | sim/bin
	rm -rf /dev/shm/obj_rand
	verilator --binary --timing -j 4 -Wno-fatal -Wno-TIMESCALEMOD \
	  rtl/oh1_pkg.sv rtl/oh1_decode.sv rtl/oh1_core.sv tb/tb_rand.sv \
	  --top-module tb_rand -Mdir /dev/shm/obj_rand -o Vtb_rand
	cp /dev/shm/obj_rand/Vtb_rand $@
	rm -rf /dev/shm/obj_rand

sim/bin:
	mkdir -p sim/bin

sim:
	@mkdir -p $(RUN_DIR)
ifeq ($(SIM),vcs)
	cd $(RUN_DIR) && vcs $(VCS_OPTS) -top tb_top && ./simv +UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED) -l sim.log $(SIMV_COV)
else ifeq ($(SIM),xrun)
	cd $(RUN_DIR) && xrun $(XRUN_OPTS) -top tb_top -define UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED)
else ifeq ($(SIM),questa)
	cd $(RUN_DIR) && vlog $(QUESTA_OPTS) && vsim -c tb_top +UVM_TESTNAME=$(TEST) -sv_seed $(SEED) -do "run -all; quit" -l sim.log
else
	@echo "不支援的 SIM=$(SIM)（可選 vcs/xrun/questa）"; exit 1
endif

# 覆蓋率回歸：三個 test（directed smoke + CRV rand + stress）各跑後以 urg 合併
# line/toggle/fsm/cond/assert 由 VCS -cm 收集；功能覆蓋由 covergroup/cover property 收集
cov:
ifeq ($(SIM),vcs)
	$(MAKE) sim SIM=vcs TEST=oh1_smoke_test COV=1
	$(MAKE) sim SIM=vcs TEST=oh1_simd_test COV=1
	$(MAKE) sim SIM=vcs TEST=oh1_rand_test COV=1
	$(MAKE) sim SIM=vcs TEST=oh1_stress_test COV=1
	cd sim && urg -dir run_*_vcs_*/cov.vdb -report urg_report -dbname merged.vdb
	@echo "合併覆蓋率報告: sim/urg_report"
else
	@echo "cov 目標目前僅實作 VCS urg；其他模擬器請用其內建 coverage 指令"
endif

clean:
	rm -rf sim/run_* csrc simv* *.vdb ucli.key
