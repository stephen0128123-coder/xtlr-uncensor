#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
星塔旅人反和谐包 v1.1 · 资源同步工具（发布者使用）

作用：游戏更新后，从【已被替换过的游戏目录】重新提取资源集，
      生成新的 data/full/ + manifest.tsv，供 build_release.py 打包。

典型场景：
  游戏从 1.4.2 更新到 1.5.0。更新过程可能覆盖掉部分反和谐文件（变回国服版），
  同时新增了新的资源包。本工具自动：
    ① 以 ss_win.mani（官方清单）为基准，找出当前目录里所有「与官方不一致」的文件
    ② 收集这些文件 → 新的资源集
    ③ 重新生成 manifest.tsv（pre/post md5 一并算好）

用法：
  python sync_assets.py --game "F:\\...\\YostarGames\\StellaSora_CN" \
                        --out  ".\\work\\v1.5.0" \
                        [--tsv "旧的manifest.tsv (可选，用于保留历史元数据)"]

产出：
  <out>/data/full/...        新的资源文件集（保持原相对路径）
  <out>/data/manifest.tsv    新清单
"""
import argparse
import hashlib
import os
import shutil
import sys

CHUNK = 1024 * 1024 * 4


def file_md5(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def read_official_manifest(game):
    """读 ss_win.mani：name|md5|size|crc"""
    p = os.path.join(game, 'Persistent_Store', 'ss_win.mani')
    if not os.path.isfile(p):
        return None
    rows = {}
    with open(p, 'r', encoding='utf-8', errors='replace') as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            parts = ln.split('|')
            if len(parts) < 4:
                continue
            name, md5, size, crc = parts[0], parts[1], parts[2], parts[3]
            rows[name] = {'md5': md5.lower(), 'size': int(size) if size.isdigit() else -1, 'crc': crc}
    return rows


def scan_layer(layer_dir):
    """扫描一层目录，返回 {相对路径: 绝对路径}"""
    out = {}
    if not os.path.isdir(layer_dir):
        return out
    for root, dirs, files in os.walk(layer_dir):
        for fn in files:
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, layer_dir)
            out[rel] = full
    return out


def main():
    ap = argparse.ArgumentParser(description='星塔旅人反和谐资源同步')
    ap.add_argument('--game', required=True, help='游戏根目录（含 xtlr.exe）')
    ap.add_argument('--out', required=True, help='输出目录')
    ap.add_argument('--tsv', default='', help='旧 manifest.tsv（可选）')
    args = ap.parse_args()

    game = args.game
    if not os.path.isfile(os.path.join(game, 'xtlr.exe')):
        print(f'[错误] {game} 不是有效的游戏目录（缺 xtlr.exe）')
        return 1

    IR = os.path.join(game, 'xtlr_Data', 'StreamingAssets', 'InstallResource')
    PS = os.path.join(game, 'Persistent_Store', 'AssetBundles')

    print('=' * 60)
    print('  星塔旅人反和谐资源同步')
    print('=' * 60)
    print(f'\n游戏目录: {game}')

    # ① 读官方清单
    official = read_official_manifest(game)
    if official is None:
        print('[错误] 找不到 Persistent_Store\\ss_win.mani')
        return 1
    print(f'官方清单: {len(official)} 项')

    # ② 扫描两层
    ir_files = scan_layer(IR)
    ps_files = scan_layer(PS)
    print(f'IR 层: {len(ir_files)} 个文件')
    print(f'PS 层: {len(ps_files)} 个文件')

    # ③ 找出「与官方不一致」的文件
    #    判据：同名文件在 PS 层与官方 md5 一致 → IR 层不同属「旧构建」，不算修改
    out_full = os.path.join(args.out, 'data', 'full')
    out_data = os.path.join(args.out, 'data')
    if os.path.isdir(os.path.join(args.out, 'data')):
        shutil.rmtree(os.path.join(args.out, 'data'))
    os.makedirs(out_full, exist_ok=True)

    # 读旧 tsv 保留历史（pre/post 元数据）
    old_rows = {}
    if args.tsv and os.path.isfile(args.tsv):
        with open(args.tsv, 'r', encoding='utf-8') as f:
            for ln in f:
                if not ln.strip():
                    continue
                p = ln.rstrip('\n').split('\t')
                if len(p) >= 6:
                    old_rows[p[1]] = p
        print(f'旧清单: {len(old_rows)} 项（用于保留元数据）')

    rows = []
    modified = []
    n_checked = 0

    for rel, full in sorted(ps_files.items()):
        basename = os.path.basename(rel)
        if basename not in official:
            # PS 层有、官方没有 → 可能是新增资源，也收
            if basename.lower().endswith(('.ab', '.bundle', '.dat', '.assets')):
                modified.append(('PS', rel, full, None, None))
            continue
        n_checked += 1
        cur_md5 = file_md5(full)
        off = official[basename]['md5']
        if cur_md5 != off:
            modified.append(('PS', rel, full, off, cur_md5))

    for rel, full in sorted(ir_files.items()):
        basename = os.path.basename(rel)
        if basename not in official:
            continue
        # 关键：若 PS 层有同名副本且与官方一致，则 IR 层不同属「旧构建」，跳过
        if rel in ps_files:
            ps_md5 = file_md5(ps_files[rel])
            if ps_md5 == official[basename]['md5']:
                continue
        n_checked += 1
        cur_md5 = file_md5(full)
        off = official[basename]['md5']
        if cur_md5 != off:
            modified.append(('IR', rel, full, off, cur_md5))

    print(f'\n已检查 {n_checked} 个文件，发现 {len(modified)} 个「与官方不一致」')

    # ④ 拷贝并生成 tsv
    tsv_lines = []
    for layer, rel, full, off_md5, cur_md5 in modified:
        dst = os.path.join(out_full, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(full, dst)

        # tsv 格式: type pkg layer pre post file
        # 保留旧元数据里的 pre（官方原始 md5）
        old = old_rows.get(os.path.basename(rel))
        pre = off_md5 or (old[3] if old and len(old) > 3 else '')
        post = cur_md5
        # 层级：如果在两层都存在，标 BOTH
        in_ir = rel in ir_files
        in_ps = rel in ps_files
        layer_field = 'BOTH' if (in_ir and in_ps) else layer
        tsv_lines.append(f'full\t{os.path.basename(rel)}\t{layer_field}\t{pre}\t{post}\t{rel}')

    tsv_path = os.path.join(out_data, 'manifest.tsv')
    with open(tsv_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(tsv_lines) + '\n')

    total_size = sum(os.path.getsize(os.path.join(out_full, r[1])) for r in modified)
    print(f'\n已输出:')
    print(f'  {out_full}  ({len(modified)} 个文件, {total_size/1024/1024:.1f} MB)')
    print(f'  {tsv_path}  ({len(tsv_lines)} 行)')
    print(f'''
下一步: python build_release.py --src "{os.path.join(args.out, 'data')}" ...
''')
    return 0


if __name__ == '__main__':
    sys.exit(main())
