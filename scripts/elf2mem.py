#!/usr/bin/env python3
"""把 ELF 拆成 imem.hex(指令) / dmem.hex(数据+tohost) / mem.hex(合并)。

用法: python elf2mem.py <test.elf> [outdir]
输出: outdir 下 imem.hex / dmem.hex / mem.hex / tohost_addr.hex
  - imem 收 .text* 段，按 word 索引 (VMA>>2) 放置
  - dmem 收 .tohost/.data/.bss/.rodata 等段
  - mem.hex 是两者的并集：统一存储器只初始化【一个】数组，PDS 综合用这份
  - 用 $readmemh 的 @addr 形式，addr 是 word 索引

两个约束（都会显式报错/警告，不再静默）:
  - imem 与 dmem 的 word 索引不得相交（共用一块 RAM，重叠会静默覆盖）
  - 既非指令段也非数据段的非空段会被丢弃，此时打警告
"""
import subprocess, sys, os, struct

# 工具链路径：可用环境变量 RISCV_TOOLS 覆盖（便于换机器/换队友）
TOOLS = os.environ.get("RISCV_TOOLS", "D:/riscv-toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin")
OBJCOPY = os.path.join(TOOLS, "riscv-none-elf-objcopy.exe")
OBJDUMP = os.path.join(TOOLS, "riscv-none-elf-objdump.exe")

IMEM_SECTIONS = {".text.init", ".text", ".text.startup"}
DMEM_SECTIONS = {".tohost", ".data", ".bss", ".sdata", ".sbss", ".rodata", ".srodata"}

# 这两个集合之外的段若 size>0，会【被静默丢弃】——是"指令凭空消失"类 bug 的温床，
# 所以 main() 里会对未归类且非空的段打警告。
# 已知可忽略：调试段（.debug*）、符号表等非 SHF_ALLOC 段。


def classify(name):
    """段名 -> 'imem' / 'dmem' / None。"""
    # .text 前缀统一当指令。不要逐个列举 ".text.init/.text/.text.startup"：
    # 一旦开了 -ffunction-sections，.text.foo 会两边都不匹配而被静默丢掉。
    if name in IMEM_SECTIONS or name.startswith(".text"):
        return "imem"
    if name in DMEM_SECTIONS:
        return "dmem"
    return None


def parse_sections(elf):
    """从 objdump -h 提取 (name, size, vma, alloc) 列表。

    objdump -h 的每个段占两行：
        0 .text.init    000002d0  00000000  00000000  00001000  2**6
                        CONTENTS, ALLOC, LOAD, READONLY, CODE
    flags 在第二行。alloc 表示 SHF_ALLOC，即"运行时要加载到内存"；
    .debug_* / .riscv.attributes 之类没有 ALLOC，本来就不该进镜像。
    """
    out = subprocess.check_output([OBJDUMP, "-h", elf], text=True)
    secs = []
    in_table = False
    cur = None                      # 上一行解析出的段，等它的 flags 行
    for line in out.splitlines():
        if line.startswith("Sections:"):
            in_table = True
            continue
        if not in_table or not line.strip():
            continue
        parts = line.split()
        # 数据行：以序号开头
        if parts[0].isdigit() and len(parts) >= 4:
            if cur is not None:
                secs.append(cur + (False,))     # 没等到 flags 行，按非分配处理
            cur = (parts[1], int(parts[2], 16), int(parts[3], 16))
            continue
        # flags 行：紧跟在数据行后面
        if cur is not None:
            secs.append(cur + ("ALLOC" in parts,))
            cur = None
    if cur is not None:
        secs.append(cur + (False,))
    return secs


def extract(elf, name, tmp):
    subprocess.check_call(
        [OBJCOPY, "-O", "binary", "--only-section=" + name, elf, tmp]
    )
    with open(tmp, "rb") as f:
        return f.read()


def group_words(data, base_vma):
    """把字节流按小端 32 位拼成 word，返回 {word_index: value}。"""
    words = {}
    for i in range(0, len(data), 4):
        chunk = data[i:i + 4]
        if len(chunk) < 4:
            chunk = chunk + b"\x00" * (4 - len(chunk))
        val = struct.unpack("<I", chunk)[0]
        words[(base_vma + i) >> 2] = val
    return words


def write_hex(path, words):
    with open(path, "w") as f:
        for idx in sorted(words):
            f.write("@%x\n%08x\n" % (idx, words[idx]))


def main():
    # 用法: python elf2mem.py <test.elf> [outdir]
    #   outdir 省略时输出到 ELF 同目录
    elf = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(elf))
    os.makedirs(outdir, exist_ok=True)
    tmp = os.path.join(outdir, "_sec.tmp.bin")
    imem = {}
    dmem = {}
    unassigned = []
    for name, size, vma, alloc in parse_sections(elf):
        if size == 0:
            continue
        kind = classify(name)
        if kind is None:
            # 只对【已分配】段报警告：.debug_* / .riscv.attributes 等本来就不进镜像
            if alloc:
                unassigned.append((name, size, vma))
            continue
        target = imem if kind == "imem" else dmem
        data = extract(elf, name, tmp)
        target.update(group_words(data, vma))

    for name, size, vma in unassigned:
        print("警告: 已分配段 %s (size=0x%x, vma=0x%x) 既非指令段也非数据段，已被丢弃"
              % (name, size, vma))

    # 两个 hex 会被 testbench 先后 $readmemh 进【同一个数组】。索引一旦相交，
    # 后读的会静默覆盖先读的 —— 必须显式报错，不能让它悄悄改变程序语义。
    overlap = set(imem) & set(dmem)
    if overlap:
        raise SystemExit(
            "错误: imem 与 dmem 的 word 索引有 %d 处重叠（最小的 0x%x）。\n"
            "      统一存储器下两者共用一块 RAM，重叠会静默覆盖。请检查链接脚本。"
            % (len(overlap), min(overlap)))

    write_hex(os.path.join(outdir, "imem.hex"), imem)
    write_hex(os.path.join(outdir, "dmem.hex"), dmem)
    # 合并镜像：真实 BRAM IP 的初始化通常只吃一份文件，PDS 综合用这个
    merged = dict(imem)
    merged.update(dmem)
    if not merged:
        raise SystemExit(
            "错误: 没有解析到任何指令/数据段，mem.hex 会是空的。\n"
            "      多半是链接脚本或段名与 elf2mem.py 的归类不符。显式报错，\n"
            "      总好过产出一份空镜像、板上什么都不跑却不报任何错。")
    write_hex(os.path.join(outdir, "mem.hex"), merged)
    # 顺便报 tohost 位置，并写入 tohost_addr.hex 供 testbench 运行时读取
    tohost = None
    for name, size, vma, alloc in parse_sections(elf):
        if name == ".tohost":
            tohost = vma
    if tohost is None:
        tohost = 0x1000  # 兜底：没有 .tohost 段时用默认地址
    with open(os.path.join(outdir, "tohost_addr.hex"), "w") as f:
        f.write("%08x\n" % tohost)
    print("tohost = 0x%x (word 0x%x)" % (tohost, tohost >> 2))
    print("imem %d 字 / dmem %d 字 / mem %d 字 -> %s"
          % (len(imem), len(dmem), len(merged), outdir))

    # 临时文件清理：必须放在【所有输出都写完】之后，且必须容错。
    # 2026-09-21 实踩 —— 这段原本排在 write_hex() 之前，而 os.remove 在某些环境
    # （沙箱拦截、被杀软或其它进程占用）会抛异常。一旦抛出，main() 会在【写出 hex
    # 之前】中止，目录里留着上一次构建的镜像：仿真和上板跑的都是旧程序，而 gcc 与
    # 本脚本都显示成功、全程无任何报错，极难排查。清理失败绝不该影响交付物。
    if os.path.exists(tmp):
        try:
            os.remove(tmp)
        except OSError as e:
            print("警告: 临时文件 %s 删除失败（%s），已忽略；不影响上面生成的 hex"
                  % (tmp, e))


if __name__ == "__main__":
    main()
