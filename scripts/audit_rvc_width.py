"""rvc_expand.v 的位宽审计器 —— 在编译前静态抓出所有拼接宽度错误。

背景：这个文件里我反复踩同一个坑 —— 拼接 {a,b,c,...} 时漏掉某个字段
（funct7/funct2/rs1），总位数变成 30/33/37 而不是 32。iverilog **不报错**，
只是左侧补 0，所有字段静默错位。所以必须有一个机械的检查。

用法：python scripts/audit_rvc_width.py
"""
import re
import sys

P = r'D:\riscv-cpu-fpga_ac\rtl\core\rvc_expand.v'

# 本文件里出现过的标识符 -> 位宽
WIDTH = {
    # 常量
    'F_ADD': 3, 'F_SLL': 3, 'F_SRL': 3, 'F_AND': 3, 'F_XOR': 3,
    'F_OR': 3, 'F_SUB': 3, 'F_LW': 3, 'F_BEQ': 3, 'F_BNE': 3,
    'OP_IMM': 7, 'OP_LOAD': 7, 'OP_STORE': 7, 'OP_REG': 7,
    'OP_BRANCH': 7, 'OP_JAL': 7, 'OP_JALR': 7, 'OP_LUI': 7,
    # 线网
    'rd': 5, 'rs2': 5, 'drd': 5, 'drs1': 5, 'drs2': 5,
    'quad': 2, 'op': 3,
    'ciimm': 6, 'lsimm': 7, 'cjimm': 12, 'cbimm': 9,
    'lwspimm': 8, 'swspimm': 8, 'nzimm4spn': 10,
    'ciimm12': 12, 'ciimm20': 20, 'lsimm12': 12, 'lwsp12': 12, 'swsp12': 12,
    'drd1': 5, 'cbimm13': 13, 'nzimm16sp': 12,
}

def width_of(part):
    part = part.strip()
    if not part:
        return None, '空'
    # 带位宽的字面量 n'bxxx / n'dxx
    m = re.match(r"^(\d+)'([bdh])(.+)$", part)
    if m:
        n = int(m.group(1))
        digits = m.group(3).replace('_', '')
        # 检查字面量位数是否超出声明宽度
        over = None
        if m.group(2) == 'b' and set(digits) <= set('01'):
            if len(digits) > n:
                over = '字面量 %d 位塞进 %d 位' % (len(digits), n)
        elif m.group(2) == 'd':
            try:
                v = int(digits)
                if v >= (1 << n):
                    over = '值 %s 超出 %d 位' % (digits, n)
            except ValueError:
                pass
        return n, over
    # 位选择单bit w[x]
    m = re.match(r'^(\w+)\[(\d+)\]$', part)
    if m:
        return 1, None
    # 位选择 w[x:y]
    m = re.match(r'^(\w+)\[(\d+):(\d+)\]$', part)
    if m:
        base = m.group(1)
        hi, lo = int(m.group(2)), int(m.group(3))
        return hi - lo + 1, None
    # 标识符
    if part in WIDTH:
        return WIDTH[part], None
    # F_xxx / OP_xxx 未登记
    if part.startswith('F_'):
        return 3, None
    if part.startswith('OP_'):
        return 7, None
    return None, '未知标识符'


def main():
    src = open(P, 'rb').read().decode('utf-8')
    lines = src.split('\n')

    # 只审计 r32 = { ... }; 这一种赋值
    problems = 0
    total = 0
    for ln, line in enumerate(lines, 1):
        m = re.search(r'r32\s*=\s*\{(.*?)\}', line)
        if not m:
            continue
        total += 1
        body = m.group(1)
        # 去掉注释
        body = re.sub(r'//.*$', '', body)
        depth = 0
        parts = []
        cur = ''
        for ch in body:
            if ch == ',' and depth == 0:
                parts.append(cur); cur = ''
                continue
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
            cur += ch
        parts.append(cur)

        total_w = 0
        issues = []
        for p in parts:
            if not p.strip():
                continue
            w, over = width_of(p)
            if w is None:
                issues.append('无法判定宽度: %s' % p.strip())
                continue
            total_w += w
            if over:
                issues.append('%s（%s）' % (p.strip(), over))

        status = 'OK' if total_w == 32 and not issues else '<<< 错误'
        if status != 'OK':
            problems += 1
        flag = '' if status == 'OK' else '  ' + '; '.join(issues)
        print('行%-4d %2d 位  %s%s' % (ln, total_w, status, flag))

    print('')
    print('审计 %d 条拼接，其中 %d 条有问题' % (total, problems))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())