#!/usr/bin/env python3
"""复盘 doc/board/uart_*.txt 五子棋串口日志。
规则：
  - 逐快照提取棋盘；'*' = 最后一手（颜色未知，记 '?'）
  - '?' 在后续快照里被解析成真色（棋子不会变色）
  - 校验：① 任何格子颜色跨快照变化 = 真 bug；② * 必须落在有子的格；
          ③ X/O 计数合法（X 先手：X==O 或 X==O+1）；④ 五连检测（4+? 报 possible）
  - 全空快照 = 新开一局，真值重置
"""
import re, sys

N = 15

def parse(path):
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    snaps, events = [], []
    i = 0
    while i < len(lines):
        if lines[i].strip().startswith('A B C D E'):
            grid = [['?'] * N for _ in range(N)]
            star, ok = None, True
            for r in range(N):
                if i + 1 + r >= len(lines):
                    ok = False; break
                m = re.match(r'\s*(\d{1,2}) ((?:[.OX*] ){14}[.OX*])\s*$', lines[i + 1 + r])
                if not m or int(m.group(1)) != r + 1:
                    ok = False; break
                toks = m.group(2).split(' ')
                if len(toks) != N:
                    ok = False; break
                for c, t in enumerate(toks):
                    if t == '*':
                        if star is not None:
                            ok = False
                        star = (r, c)
                    else:
                        grid[r][c] = t
            if ok:
                meta = lines[i + 1 + N].strip() if i + 1 + N < len(lines) else ''
                snaps.append((i + 1, grid, star, meta))
                i += 1 + N
                continue
        ln = lines[i].strip()
        if ln and not ln.startswith('#'):
            events.append((i + 1, ln))
        i += 1
    return snaps, events

def check(path):
    snaps, events = parse(path)
    print(f"=== {path}: {len(snaps)} snapshots ===")
    truth = [['.'] * N for _ in range(N)]   # '.' 空 / 'X' / 'O' / '?' 被 * 遮住
    problems = 0
    for idx, (lineno, grid, star, meta) in enumerate(snaps):
        occupied = sum(1 for r in range(N) for c in range(N) if grid[r][c] != '.')
        if occupied == 0:
            truth = [['.'] * N for _ in range(N)]
            print(f"snap#{idx} @L{lineno}: (空盘 - 新局)")
            continue
        msgs = []
        # 1) * 遮住的格子：真值里记 '?'（若已是子则保留真色）
        if star:
            r, c = star
            if truth[r][c] == '.':
                truth[r][c] = '?'
            elif truth[r][c] == '?':
                pass
            # 若真值已是 X/O 而本帧又打 * —— 旧标记没动，记录
            else:
                msgs.append(f"note: * 落在已有真色的格 r{r+1}c{chr(65+c)}={truth[r][c]}")
        # 2) 颜色稳定性 + 回填真值
        for r in range(N):
            for c in range(N):
                v = grid[r][c]
                if v == '?':
                    continue
                t = truth[r][c]
                if t in ('.', '?'):
                    truth[r][c] = v            # 新子 / * 的真色被解析
                elif t != v:
                    msgs.append(f"!! 格子 r{r+1}c{chr(65+c)} 颜色 {t} -> {v}（棋子变色！）")
                    problems += 1
        # 3) * 必须遮住一颗子（真值非 '.'）
        if star and truth[star[0]][star[1]] == '.':
            msgs.append(f"!! * 在空格 r{star[0]+1}c{chr(65+star[1])}")
            problems += 1
        # 4) 计数合法
        xs = sum(row.count('X') for row in truth)
        os_ = sum(row.count('O') for row in truth)
        qs = sum(row.count('?') for row in truth)
        if not (xs == os_ or xs == os_ + 1):
            msgs.append(f"!! 计数 X={xs} O={os_}（X 应先手：X==O 或 X==O+1）")
            problems += 1
        # 5) 五连（'?' 算通配但必须遮住子）
        for color in ('X', 'O'):
            for r in range(N):
                for c in range(N):
                    for dr, dc in ((0, 1), (1, 0), (1, 1), (1, -1)):
                        cells = [(r + dr * k, c + dc * k) for k in range(5)]
                        if not all(0 <= rr < N and 0 <= cc < N for rr, cc in cells):
                            continue
                        vals = [truth[rr][cc] for rr, cc in cells]
                        if vals.count(color) == 5:
                            msgs.append(f"** {color} 五连: {[(rr+1, chr(65+cc)) for rr, cc in cells]}")
                        elif vals.count(color) == 4 and '?' in vals:
                            msgs.append(f"?? {color} 四连+*(可能五连): {[(rr+1, chr(65+cc)) for rr, cc in cells]}")
        star_txt = f"*=r{star[0]+1}c{chr(65+star[1])}" if star else "*=None"
        print(f"snap#{idx} @L{lineno}: X={xs} O={os_} ?={qs} {star_txt} {' | '.join(msgs)}")
        if meta.startswith('cursor='):
            print(f"      {meta}")
    for ln, txt in events:
        if 'wins' in txt or txt in ('title',) or 'AI match' in txt or txt.startswith('start,') or 'occupied' in txt or 'thinking' in txt:
            print(f"  event @L{ln}: {txt}")
    print(f"problems: {problems}\n")
    return problems

if __name__ == '__main__':
    total = sum(check(p) for p in sys.argv[1:])
    sys.exit(1 if total else 0)
