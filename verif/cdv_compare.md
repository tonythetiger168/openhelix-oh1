# Coverage-driven vs plain constrained-random: functional closure

Seeds [1, 2, 3, 4, 5, 6, 7, 8], budget 160 kernels per run, batches of 4 kernels, every run in its own simulation. Bins are the functional bins reachable in that build (bins tagged with the other memory-timing build are left out). Medians over seeds; "(k/n runs)" means only k of n runs got there within the budget.


## SYNC_MEM=0 build (953 bins)

| Generator | kernels to 90% | kernels to 95% | kernels to 99% | kernels to 100% | cycles to 100% | covered at budget (median, min) |
|---|---:|---:|---:|---:|---:|---:|
| plain CRV | not reached (0/8) | not reached (0/8) | not reached (0/8) | not reached (0/8) | not reached (0/8) | 836 / 953, min 825 |
| coverage-driven | 44 | 56 | 68 | 92 (6/8 runs) | 77,792 (6/8 runs) | 953 / 953, min 952 |

Holes plain CRV leaves at the budget, by cover item (summed over seeds): `oh1.soc.wr.reg_x_strb` 312, `oh1.exec.seq.raw.prod_x_cons` 206, `oh1.exec.kind_x_lanes` 57, `oh1.soc.rd.reg` 56, `oh1.soc.exit.kind_x_fault` 48, `oh1.exec.split.type_x_depth` 44, `oh1.soc.wr.reg` 40, `oh1.exec.tmc.arg_x_before` 33, `oh1.soc.wr.reg_strb` 24, `oh1.exec.alu.kind_x_rd` 22, `oh1.exec.seq.redir.type_x_next` 17, `oh1.exec.join.type_x_depth` 13.

Holes coverage-driven runs still had at the budget: `oh1.soc.start_ignored at_exit`.

## SYNC_MEM=1 build (953 bins)

| Generator | kernels to 90% | kernels to 95% | kernels to 99% | kernels to 100% | cycles to 100% | covered at budget (median, min) |
|---|---:|---:|---:|---:|---:|---:|
| plain CRV | not reached (0/8) | not reached (0/8) | not reached (0/8) | not reached (0/8) | not reached (0/8) | 833 / 953, min 824 |
| coverage-driven | 44 | 56 | 68 | 116 (2/8 runs) | 92,250 (2/8 runs) | 952 / 953, min 949 |

Holes plain CRV leaves at the budget, by cover item (summed over seeds): `oh1.soc.wr.reg_x_strb` 312, `oh1.exec.seq.raw.prod_x_cons` 221, `oh1.soc.rd.reg` 56, `oh1.exec.split.type_x_depth` 51, `oh1.soc.exit.kind_x_fault` 49, `oh1.exec.kind_x_lanes` 45, `oh1.soc.wr.reg` 40, `oh1.exec.tmc.arg_x_before` 34, `oh1.soc.wr.reg_strb` 24, `oh1.exec.alu.kind_x_rd` 22, `oh1.exec.seq.redir.type_x_next` 21, `oh1.exec.split.ovf` 12.

Holes coverage-driven runs still had at the budget: `oh1.exec.kind_x_lanes ('SRLI', 2)`, `oh1.exec.seq.raw.prod_x_cons ('upper', 'sw_base')`, `oh1.exec.seq.raw.prod_x_cons ('vdot', 'lw_base')`, `oh1.exec.tmc.arg_x_before (2, 0)`, `oh1.soc.start_ignored at_exit`.
