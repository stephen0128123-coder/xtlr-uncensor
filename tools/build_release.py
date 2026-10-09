#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
星塔旅人反和谐包 v2.0 · 发布打包工具（部署端使用）

作用：把 v1.0 的 data/full/ 资源包，打包成适合 GitHub Release 的形态：
  1. 可选切分（单个 Release asset 上限 2GB，超了必须切）
  2. 计算每个分包的 size + md5 + sha256
  3. 生成 manifest.json（供安装器读取）
  4. 输出到 dist/ 目录，直接拖进 GitHub Release 即可

用法：
  python build_release.py --src "D:\\...\\星塔旅人_反和谐包_v1.0\\data" ^
                          --out "D:\\...\\星塔旅人_GH分发_v2.0\\dist" ^
                          --repo "yourname/yourrepo" ^
                          --version 2.0.0 --game-version 1.4.2 ^
                          --split-mb 1800
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import zipfile
from datetime import date

CHUNK = 1024 * 1024 * 8  # 8MB 读取块


def file_md5(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def human(n):
    for u in ['B', 'KB', 'MB', 'GB', 'TB']:
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


def make_zip(src_dir, zip_path, arc_prefix=''):
    """把 src_dir 下所有内容打进 zip（保持相对目录结构）"""
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        for root, dirs, files in os.walk(src_dir):
            for fn in sorted(files):
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, src_dir)
                arc = os.path.join(arc_prefix, rel) if arc_prefix else rel
                z.write(full, arc.replace('\\', '/'))
                yield rel


def split_file(src, out_dir, base_name, split_bytes):
    """把大文件切成若干份，返回生成的文件名列表"""
    parts = []
    size = os.path.getsize(src)
    if size <= split_bytes:
        dst = os.path.join(out_dir, base_name)
        if os.path.abspath(dst) != os.path.abspath(src):
            shutil.copy2(src, dst)
        return [base_name]

    n = (size + split_bytes - 1) // split_bytes
    with open(src, 'rb') as f:
        for i in range(n):
            part_name = f"{base_name}.part{i+1:02d}"
            dst = os.path.join(out_dir, part_name)
            remain = min(split_bytes, size - i * split_bytes)
            with open(dst, 'wb') as o:
                while remain > 0:
                    chunk = f.read(min(CHUNK, remain))
                    if not chunk:
                        break
                    o.write(chunk)
                    remain -= len(chunk)
            parts.append(part_name)
    return parts


def main():
    ap = argparse.ArgumentParser(description='星塔旅人反和谐包 v2.0 发布打包')
    ap.add_argument('--src', required=True, help='v1.0 的 data 目录（含 full/ 与 manifest.tsv）')
    ap.add_argument('--out', required=True, help='输出目录（dist）')
    ap.add_argument('--repo', required=True, help='GitHub 仓库，如 yourname/xtlr-uncensor')
    ap.add_argument('--version', default='2.0.0', help='包版本号（不带 v）')
    ap.add_argument('--game-version', default='1.4.2', help='对应游戏版本')
    ap.add_argument('--split-mb', type=int, default=1800, help='单个 asset 切分上限(MB)，默认 1800')
    ap.add_argument('--notes', default='', help='Release 说明')
    args = ap.parse_args()

    src_data = args.src
    src_full = os.path.join(src_data, 'full')
    src_tsv  = os.path.join(src_data, 'manifest.tsv')

    if not os.path.isdir(src_full):
        print(f'[错误] 找不到资源目录: {src_full}')
        return 1
    if not os.path.isfile(src_tsv):
        print(f'[错误] 找不到清单文件: {src_tsv}')
        return 1

    out = args.out
    stage = os.path.join(out, '_stage')
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage, exist_ok=True)

    print('=' * 60)
    print('  星塔旅人反和谐包 v2.0 · 发布打包')
    print('=' * 60)

    # ① 统计源文件
    total_files = 0
    total_size = 0
    for root, dirs, files in os.walk(src_full):
        for fn in files:
            total_files += 1
            total_size += os.path.getsize(os.path.join(root, fn))
    print(f'\n源资源: {total_files} 个文件 / {human(total_size)}')

    # ② 先把 full/ 打成一个 zip（再切分）
    print('\n[1/4] 打包资源为 zip ...')
    big_zip = os.path.join(stage, 'data.zip')
    for rel in make_zip(src_full, big_zip):
        pass
    zip_size = os.path.getsize(big_zip)
    print(f'      data.zip -> {human(zip_size)}')

    # ③ 切分
    print(f'\n[2/4] 切分（上限 {args.split_mb} MB/个）...')
    out_assets_dir = os.path.join(out, 'assets')
    if os.path.isdir(out_assets_dir):
        shutil.rmtree(out_assets_dir)
    os.makedirs(out_assets_dir, exist_ok=True)

    split_bytes = args.split_mb * 1024 * 1024
    parts = split_file(big_zip, out_assets_dir, 'data.zip', split_bytes)
    print(f'      切分为 {len(parts)} 个分片')
    for p in parts:
        print(f'        {p}  ({human(os.path.getsize(os.path.join(out_assets_dir, p)))})')

    # ④ 拷 manifest.tsv
    shutil.copy2(src_tsv, os.path.join(out_assets_dir, 'manifest.tsv'))
    print(f'      manifest.tsv 已复制')

    # ⑤ 算校验值，生成 manifest.json
    print('\n[3/4] 计算校验值 ...')
    assets = []
    for p in parts:
        fp = os.path.join(out_assets_dir, p)
        assets.append({
            'name': p,
            'size': os.path.getsize(fp),
            'md5': file_md5(fp),
            'sha256': file_sha256(fp),
        })
        print(f'        {p}  md5={assets[-1]["md5"]}')

    tsv_path = os.path.join(out_assets_dir, 'manifest.tsv')
    tsv_info = {
        'name': 'manifest.tsv',
        'size': os.path.getsize(tsv_path),
        'md5': file_md5(tsv_path),
    }

    tag = f'v{args.version}'
    gh_base = f'https://github.com/{args.repo}/releases/download/{tag}/'

    manifest = {
        'schema': 2,
        'package_version': args.version,
        'game_version': args.game_version,
        'game': 'stellasora-cn',
        'updated': date.today().isoformat(),
        'notes': args.notes or f'对应国服 {args.game_version} 版本的反和谐资源包',
        'channels': [
            {'id': 'github',  'name': 'GitHub 直连',       'base': gh_base},
            {'id': 'ghproxy', 'name': 'ghproxy.net 镜像',  'base': 'https://ghproxy.net/' + gh_base},
            {'id': 'gh-proxy','name': 'gh-proxy.com 镜像', 'base': 'https://gh-proxy.com/' + gh_base},
            {'id': 'ghfast',  'name': 'ghfast.top 镜像',   'base': 'https://ghfast.top/' + gh_base},
        ],
        'assets': assets,
        'manifest_tsv': tsv_info,
    }

    mani_path = os.path.join(out_assets_dir, 'manifest.json')
    with open(mani_path, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(f'      manifest.json 已生成')

    # ⑥ 清理中间产物
    print('\n[4/4] 清理 ...')
    shutil.rmtree(stage, ignore_errors=True)

    # ⑦ 输出汇总
    print('\n' + '=' * 60)
    print('  打包完成')
    print('=' * 60)
    print(f'\n输出目录: {out_assets_dir}')
    print(f'需要上传到 GitHub Release 的文件：\n')
    for p in sorted(os.listdir(out_assets_dir)):
        fp = os.path.join(out_assets_dir, p)
        print(f'  {p:28s}  {human(os.path.getsize(fp))}')
    print(f'\nRebuild Release tag 建议: {tag}')
    print(f'Release 标题建议: v{args.version} (游戏 {args.game_version})')
    print(f'''
下一步（手动）：
  1. 打开 https://github.com/{args.repo}/releases/new
  2. Tag 填 {tag}，标题填 v{args.version} (游戏 {args.game_version})
  3. 把上面这些文件全部拖进去上传
  4. 点 Publish release

以后更新只需重复：改 manifest 前的源数据 -> 重跑本脚本 -> 传新 Release
''')
    return 0


if __name__ == '__main__':
    sys.exit(main())
