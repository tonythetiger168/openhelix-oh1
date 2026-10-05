// OpenHelix 標準 verilator main（Debian 套件未附 verilated_main.cpp）
// 用法: verilator --cc --timing --exe --build sim/verilator_main.cpp ... -o Vtb
#include "Vtb_smoke.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_smoke* top = new Vtb_smoke;
    vluint64_t t = 0;
    while (!Verilated::gotFinish() && t < 1000000) {
        top->eval();
        Verilated::timeInc(1);
        t++;
    }
    top->final();
    delete top;
    return 0;
}
