# RV32IMA 顺序双发射 SoC：一颗位流，三路径

基于紫光同创 Logos2 PG2L200H FPGA 的 RV32IMA 顺序双发射 SoC：自研五级流水线双发射 CPU 核、128KB 统一存储器、tile PPU 与 HDMI 显示链路。板上实测 CoreMark 352.5（4.6075 CoreMark/MHz @76.5052 MHz），LUT 占用 4.84%，CPU 域 WNS +0.304 ns 全约束收敛。

## 目录说明

- `rtl/` —— 设计代码（CPU 核 / 总线 / 统一存储器 / 外设 / 视频子系统）
- `sim/` —— 仿真测试台（riscv-tests 回归、CoreMark 仿真）
- `scripts/` —— 一键构建脚本与固件源码（boot / coremark_port / demo / gomoku / rtthread）
- `pds/` —— Pango Design Suite 2022.2-SP6.4 工程与固件镜像 `mem.hex`
- `third_party/` —— CoreMark、RT-Thread、riscv-tests 上游基线

## 一键复现

1. 位流：PDS 打开 `pds/RV32I_1/RV32I_1.pds` → 综合 → 布局布线 → 生成位流
2. 固件：各固件目录内 `build.ps1`（riscv-none-elf-gcc），`scripts/elf2mem.py` 生成 `mem.hex`
3. 上电三路径：默认进 RT-Thread 五子棋；按住 SW6 复位 → 裸机 CoreMark；SW6+SW7 复位 → 终端监控屏
