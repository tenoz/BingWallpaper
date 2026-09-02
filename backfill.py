#!/usr/bin/env python3
"""必应壁纸历史回填（任务 A）

从 GitHub 仓库 niumoo/bing-wallpaper 的月度 README 索引解析出「日期 → 图片 ID」，
自行拼裸 _UHD.jpg 直链下载 4K 原图。

实测结论（2026-09-02，勿凭直觉改动）：
1. 只能取 README 里的 id= 参数自行拼 https://www.bing.com/th?id=<ID>_UHD.jpg。
   README 原链带 &w=3840&h=2160，CDN 会重压：同为 3840x2160，体积 2.4MB vs 3.8MB（少 36%），
   MD5 与 App 下载的不一致 → 照抄原链会下到次品。
2. 文件名保留驼峰（对齐 App 的 stripMarket），仅去重键用大写。
3. 仓库日期 = zh-CN 接口 startdate + 2 天。按老大决定，本脚本采用仓库日期（不减 2）。
4. 去重只看 App 已下载集合（downloaded.json）+ 目录现有文件，不回写清单：
   App 接口窗口仅最近 16 天，与历史图不重叠，回写反而与运行中的 App 抢文件。
"""

import argparse
import json
import re
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from pathlib import Path

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
REPO_RAW = "https://raw.githubusercontent.com/niumoo/bing-wallpaper/main/picture/{}/README.md"
API_DIRS = "https://api.github.com/repos/niumoo/bing-wallpaper/contents/picture"
# 索引每行 3 个 cell：![](缩略图)YYYY-MM-DD [download 4k](直链)
ENTRY_RE = re.compile(r"(\d{4}-\d{2}-\d{2}) \[download 4k\]\((https://[^)]+)\)")
ID_RE = re.compile(r"[?&]id=([^&]+)")
# 与 App 的 stripMarket 同序：先剥 _UHD.jpg，再剥市场后缀 _EN-US123
STRIP = [re.compile(r"_UHD\.jpg$"), re.compile(r"_[A-Za-z]{2}-[A-Za-z]{2}\d+$")]
MIN_SIZE = 100_000
JPEG_MAGIC = b"\xff\xd8\xff"
MANIFEST = Path.home() / "Library/Application Support/BingWallpaper/downloaded.json"


def fetch(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def strip_market(s):
    for p in STRIP:
        s = p.sub("", s)
    return s


def months(start, end):
    data = json.loads(fetch(API_DIRS))
    names = sorted(e["name"] for e in data if re.fullmatch(r"\d{4}-\d{2}", e["name"]))
    return [m for m in names if start <= m <= end]


def parse_month(month, retries=3):
    """返回 [(日期, 驼峰名, 原始 id), ...]

    实测单次拉取偶发 SSL 握手超时（68 个月里约 3 次），不重试会静默丢掉整月。
    """
    text = None
    for i in range(retries):
        try:
            text = fetch(REPO_RAW.format(month)).decode("utf-8", "replace")
            break
        except Exception:
            if i == retries - 1:
                raise
            time.sleep(1 + i)
    out = []
    for d, link in ENTRY_RE.findall(text):
        m = ID_RE.search(link)
        if m:
            raw = m.group(1)
            out.append((d, strip_market(raw), raw))
    return out


def known_ids(dest):
    """已下载集合 = 目录现有文件 + App 清单。

    去重键统一为全大写且自带 OHR. 前缀（如 OHR.YELLOWSHARK），
    与 downloaded.json 中 App 写入的形态一致。
    注意：strip_market 返回的 name 已含 OHR. 前缀，勿重复拼接。
    """
    ids = set()
    for p in dest.glob("*_OHR.*.jpg"):
        if "_" in p.stem:
            ids.add(p.stem.split("_", 1)[1].upper())
    if MANIFEST.exists():
        try:
            ids |= set(json.loads(MANIFEST.read_text()))
        except Exception:
            pass
    return ids


def download(item, dest, retries=3):
    d, name, raw = item
    fname = "{}_{}.jpg".format(d, name)
    path = dest / fname
    if path.exists() and path.stat().st_size >= MIN_SIZE:
        return "skip", fname, ""
    tail = raw if raw.endswith("_UHD.jpg") else raw + "_UHD.jpg"
    url = "https://www.bing.com/th?id=" + tail
    err = ""
    for attempt in range(retries):
        try:
            data = fetch(url, timeout=60)
            if len(data) < MIN_SIZE or not data.startswith(JPEG_MAGIC):
                err = "异常响应 {}B".format(len(data))
                time.sleep(1)
                continue
            tmp = path.with_name(fname + ".part")
            tmp.write_bytes(data)
            tmp.replace(path)
            return "ok", fname, ""
        except Exception as e:
            err = str(e)
            time.sleep(1 + attempt)
    return "fail", fname, err


def main():
    ap = argparse.ArgumentParser(description="必应壁纸历史回填（任务 A）")
    ap.add_argument("--dir", default=str(Path.home() / "Pictures" / "bing-wallpaper"),
                    help="壁纸存放目录")
    ap.add_argument("--start", default="2021-02", help="起始月份 YYYY-MM")
    ap.add_argument("--end", default=date.today().strftime("%Y-%m"), help="结束月份 YYYY-MM")
    ap.add_argument("--workers", type=int, default=6, help="并发数")
    ap.add_argument("--dry-run", action="store_true", help="只列清单不下载")
    a = ap.parse_args()

    dest = Path(a.dir).expanduser()
    if not dest.is_dir():
        sys.exit("目录不存在：{}".format(dest))

    known = known_ids(dest)
    ms = months(a.start, a.end)
    if not ms:
        sys.exit("该范围内没有月份索引")
    print("月份范围：{} ~ {}（{} 个月）".format(ms[0], ms[-1], len(ms)))

    tasks = []
    for m in ms:
        try:
            tasks += parse_month(m)
        except Exception as e:
            print("  ! {} 索引拉取失败：{}".format(m, e))

    # 同图去重（README 顶部 Today 行会与表格重复）；name 形如 OHR.YellowShark，已含前缀
    seen, uniq = set(), []
    for it in tasks:
        key = it[1].upper()
        if key not in seen:
            seen.add(key)
            uniq.append(it)

    todo = [it for it in uniq if it[1].upper() not in known]
    print("索引 {} 条 → 去重后 {} → 待下载 {}（已有 {}）".format(
        len(tasks), len(uniq), len(todo), len(uniq) - len(todo)))

    if a.dry_run:
        for it in todo[:20]:
            print("   {}_{}.jpg".format(it[0], it[1]))
        if len(todo) > 20:
            print("   ...（共 {} 个）".format(len(todo)))
        return

    ok = skip = 0
    failed = []
    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        futs = [ex.submit(download, it, dest) for it in todo]
        for i, f in enumerate(as_completed(futs), 1):
            st, name, err = f.result()
            if st == "ok":
                ok += 1
            elif st == "skip":
                skip += 1
            else:
                failed.append((name, err))
            if i % 50 == 0 or i == len(todo):
                print("  进度 {}/{}  成功 {}  跳过 {}  失败 {}".format(
                    i, len(todo), ok, skip, len(failed)))

    print("\n完成：成功 {}  跳过 {}  失败 {}".format(ok, skip, len(failed)))
    if failed:
        print("失败清单（重跑本脚本即可续传）：")
        for n, e in failed:
            print("  {}  {}".format(n, e))


if __name__ == "__main__":
    main()
