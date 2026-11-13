#!/bin/zsh
set -u

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

INPUT="${1:-}"
LANGUAGE="${2:-}"
FORMAT="${3:-}"
OUTPUT="${4:-}"
PARSER="${5:-local}"
TMP_DIR=""
OCR_PDF=""
SIDECAR=""
PART="${OUTPUT}.part"
CHILD_PID=""

cleanup() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  rm -f "$PART"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -z "$INPUT" || -z "$LANGUAGE" || -z "$FORMAT" || -z "$OUTPUT" ]]; then
  print -u2 "ERROR=参数不足"
  exit 2
fi

if [[ "$FORMAT" != "txt" && "$FORMAT" != "epub" && "$FORMAT" != "md" ]]; then
  print -u2 "ERROR=不支持的输出格式"
  exit 2
fi

if [[ "$PARSER" != "local" && "$PARSER" != "mineru" ]]; then
  print -u2 "ERROR=不支持的解析方式"
  exit 2
fi

OCR_BIN=""
for candidate in "$(command -v ocrmypdf 2>/dev/null || true)" /usr/local/bin/ocrmypdf /opt/homebrew/bin/ocrmypdf; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    OCR_BIN="$candidate"
    break
  fi
done

TESSERACT_BIN=""
for candidate in "$(command -v tesseract 2>/dev/null || true)" /usr/local/bin/tesseract /opt/homebrew/bin/tesseract; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    TESSERACT_BIN="$candidate"
    break
  fi
done

PYTHON_BIN=""
for candidate in "$(command -v python3 2>/dev/null || true)" /usr/local/bin/python3 /opt/homebrew/bin/python3; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    PYTHON_BIN="$candidate"
    break
  fi
done

QPDF_BIN=""
for candidate in "$(command -v qpdf 2>/dev/null || true)" /usr/local/bin/qpdf /opt/homebrew/bin/qpdf; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    QPDF_BIN="$candidate"
    break
  fi
done

GS_BIN=""
for candidate in "$(command -v gs 2>/dev/null || true)" /usr/local/bin/gs /opt/homebrew/bin/gs; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    GS_BIN="$candidate"
    break
  fi
done

if [[ -z "$PYTHON_BIN" ]]; then
  print -u2 "ERROR=找不到 Python 3"
  exit 127
fi

if [[ "$PARSER" == "local" && ( -z "$OCR_BIN" || -z "$TESSERACT_BIN" ) ]]; then
  print -u2 "ERROR=找不到 OCRmyPDF 或 Tesseract"
  exit 127
fi

if [[ "$PARSER" == "mineru" && -z "$QPDF_BIN" ]]; then
  print -u2 "ERROR=找不到 qpdf，无法为 MinerU 拆分页数较多的 PDF"
  exit 127
fi

if [[ ! -f "$INPUT" ]]; then
  print -u2 "ERROR=输入 PDF 不存在"
  exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$PART"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reflow-txt-epub.XXXXXX")"
OCR_PDF="$TMP_DIR/ocr.pdf"
SIDECAR="$TMP_DIR/ocr.txt"
print "TEMP_DIR=$TMP_DIR"
print "PART_PATH=$PART"
if [[ -n "$QPDF_BIN" ]]; then
  TOTAL_PAGES="$("$QPDF_BIN" --show-npages "$INPUT" 2>/dev/null || true)"
  if [[ "$TOTAL_PAGES" == <-> ]]; then
    print "TOTAL_PAGES=$TOTAL_PAGES"
  fi
fi

if [[ "$PARSER" == "mineru" ]]; then
  print "PHASE=MINERU"
  print "STATUS=正在用 MinerU 精准解析 PDF"
  "$PYTHON_BIN" - "$INPUT" "$LANGUAGE" "$FORMAT" "$PART" "$TMP_DIR" "$QPDF_BIN" <<'PY' &
from datetime import datetime, timezone
from html import escape
from pathlib import Path
from urllib import error, request
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
import zipfile

input_pdf = Path(sys.argv[1])
language_code = sys.argv[2]
output_format = sys.argv[3]
part_output = Path(sys.argv[4])
temp_dir = Path(sys.argv[5])
qpdf_bin = sys.argv[6]

MAX_PAGES_PER_PART = 200
MAX_BYTES_PER_PART = 199 * 1024 * 1024
MAX_FILES_PER_BATCH = 50
API_ROOT = "https://mineru.net/api/v4"

def emit(message):
    print(message, flush=True)

def fail(message):
    emit(f"ERROR={message}")
    raise SystemExit(1)

def mineru_token():
    value = os.environ.get("MINERU_TOKEN", "").strip()
    if not value:
        fail("没有找到 MinerU Token，请在 App 界面填写后再开始")
    return value

def qpdf_pages(path):
    result = subprocess.run([qpdf_bin, "--show-npages", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        fail("无法读取 PDF 页数")
    try:
        return int(result.stdout.strip())
    except ValueError:
        fail("无法解析 PDF 页数")

def split_pdf():
    total = qpdf_pages(input_pdf)
    emit(f"TOTAL_PAGES={total}")
    parts = []
    current = 1
    index = 1
    split_dir = temp_dir / "mineru_parts"
    split_dir.mkdir(parents=True, exist_ok=True)
    while current <= total:
        span = min(MAX_PAGES_PER_PART, total - current + 1)
        while True:
            end = current + span - 1
            part_path = split_dir / f"part_{index:03d}_{current}-{end}.pdf"
            if part_path.exists():
                part_path.unlink()
            cmd = [qpdf_bin, str(input_pdf), "--pages", str(input_pdf), f"{current}-{end}", "--", str(part_path)]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.stderr.strip():
                emit("LOG=" + result.stderr.strip().replace("\n", " | ")[:500])
            if result.returncode != 0 and (not part_path.exists() or part_path.stat().st_size == 0):
                detail = (result.stderr or result.stdout or "").strip()
                fail(f"PDF 拆分失败：{detail[:300] or 'qpdf 没有生成分段文件'}")
            if part_path.stat().st_size <= MAX_BYTES_PER_PART or span == 1:
                parts.append({"path": part_path, "name": part_path.name, "start": current, "end": end, "pages": span})
                emit(f"STATUS=已拆分第 {current}-{end} 页")
                current = end + 1
                index += 1
                break
            span = max(1, span // 2)
    return total, parts

def http_json(url, method="GET", token=None, payload=None):
    data = None
    headers = {"Accept": "*/*"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = request.Request(url, data=data, method=method, headers=headers)
    try:
        with request.urlopen(req, timeout=60) as response:
            body = response.read().decode("utf-8", errors="replace")
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"MinerU API HTTP {exc.code}: {body[:300]}")
    except Exception as exc:
        fail(f"MinerU API 请求失败：{exc}")
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError:
        fail(f"MinerU API 返回不是 JSON：{body[:300]}")
    if decoded.get("code") != 0:
        fail(f"MinerU API 返回错误：{decoded.get('msg') or decoded}")
    return decoded

def upload_file(url, path):
    curl = shutil.which("curl") or "/usr/bin/curl"
    result = subprocess.run(
        [curl, "-fL", "-sS", "-X", "PUT", "-T", str(path), url],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        fail(f"上传到 MinerU 失败：{detail[:300] or 'curl 返回错误'}")

def apply_for_uploads(token, batch):
    files = []
    for part in batch:
        files.append({
            "name": part["name"],
            "data_id": part["name"].removesuffix(".pdf"),
            "is_ocr": True,
        })
    payload = {
        "files": files,
        "model_version": "vlm",
        "language": "ch",
        "enable_formula": True,
        "enable_table": True,
    }
    decoded = http_json(f"{API_ROOT}/file-urls/batch", method="POST", token=token, payload=payload)
    data = decoded.get("data") or {}
    batch_id = data.get("batch_id")
    urls = data.get("file_urls") or []
    if not batch_id or len(urls) != len(batch):
        fail("MinerU 没有返回有效的上传链接")
    return batch_id, urls

def poll_batch(token, batch_id, batch, total_pages, done_before):
    expected = {part["name"].removesuffix(".pdf"): part for part in batch}
    done = {}
    last_status = ""
    while len(done) < len(batch):
        decoded = http_json(f"{API_ROOT}/extract-results/batch/{batch_id}", token=token)
        data = decoded.get("data") or {}
        results = data.get("extract_result") or []
        if isinstance(results, dict):
            results = [results]
        running_pages = 0
        for item in results:
            data_id = item.get("data_id") or Path(item.get("file_name", "")).stem
            state = item.get("state", "")
            part = expected.get(data_id)
            if state == "failed":
                fail(f"MinerU 解析失败：{item.get('err_msg') or item.get('file_name') or data_id}")
            if state == "done" and item.get("full_zip_url"):
                done[data_id] = item["full_zip_url"]
            elif part:
                progress = item.get("extract_progress") or {}
                running_pages += min(part["pages"], int(progress.get("extracted_pages") or 0))
        done_pages = done_before + sum(expected[key]["pages"] for key in done if key in expected) + running_pages
        percent = min(88.0, max(5.0, done_pages / max(total_pages, 1) * 88.0))
        status = f"MinerU 解析中：约第 {min(done_pages, total_pages)} / {total_pages} 页"
        if status != last_status:
            emit(f"STATUS={status}")
            last_status = status
        emit(f"PROGRESS={percent:.2f}")
        if len(done) < len(batch):
            time.sleep(10)
    return done

def download_full_md(url, target_dir):
    zip_path = target_dir / (uuid.uuid4().hex + ".zip")
    try:
        request.urlretrieve(url, zip_path)
    except Exception as exc:
        fail(f"下载 MinerU 结果失败：{exc}")
    extract_dir = target_dir / zip_path.stem
    extract_dir.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(extract_dir)
    except Exception as exc:
        fail(f"解压 MinerU 结果失败：{exc}")
    candidates = sorted(extract_dir.rglob("full.md"))
    if not candidates:
        candidates = sorted(extract_dir.rglob("*.md"))
    if not candidates:
        fail("MinerU 结果中没有找到 Markdown 文件")
    return candidates[0].read_text(encoding="utf-8", errors="replace").strip()

def markdown_for_text(md):
    md = md.replace("\r\n", "\n").replace("\r", "\n")
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    md = re.sub(r"!\[[^\]]*\]\([^)]+\)", "", md)
    md = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", md)
    md = re.sub(r"^[ \t]*#{1,6}[ \t]*(.+)$", r"\1", md, flags=re.M)
    md = re.sub(r"^[ \t]*[-*_]{3,}[ \t]*$", "", md, flags=re.M)
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md.strip()

def markdown_for_md(md):
    md = md.replace("\r\n", "\n").replace("\r", "\n")
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    md = re.sub(r"!\[[^\]]*\]\([^)]+\)", "", md)
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md.strip()

def merge_text_chunks(chunks):
    paragraphs = []
    for chunk in chunks:
        cleaned = chunk.strip()
        if not cleaned:
            continue
        parts = [part.strip() for part in re.split(r"\n\s*\n", cleaned) if part.strip()]
        if not parts:
            continue
        if paragraphs:
            previous = paragraphs[-1]
            first = parts[0]
            previous_ended = bool(re.search(r"[。！？!?；;：:」』）)]$", previous))
            next_is_title = len(first) <= 40 and not re.search(r"[。！？!?]$", first)
            if not previous_ended and not next_is_title:
                paragraphs[-1] = previous + first
                parts = parts[1:]
        paragraphs.extend(parts)
    return "\n\n".join(paragraphs).strip() + "\n"

def merge_md_chunks(chunks):
    cleaned = [chunk.strip() for chunk in chunks if chunk.strip()]
    return "\n\n".join(cleaned).strip() + "\n"

def markdown_to_epub(text):
    title = input_pdf.stem.replace("_", " ")
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", text) if part.strip()]
    body = []
    for index, paragraph in enumerate(paragraphs, 1):
        is_title = len(paragraph) <= 40 and not re.search(r"[。！？!?]$", paragraph)
        if is_title:
            body.append(f'<h2 id="h-{index}">{escape(paragraph)}</h2>')
        else:
            body.append(f"<p>{escape(paragraph)}</p>")
    if not body:
        fail("没有可写入 EPUB 的文本")

    book_id = "book-" + uuid.uuid4().hex
    modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    content = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <title>{escape(title)}</title>
  <style>
    body {{ margin: 0; padding: 0 4%; line-height: 1.65; }}
    h1 {{ text-align: center; margin: 2em 0; }}
    h2 {{ margin: 1.6em 0 0.8em; font-weight: bold; }}
    p {{ margin: 0 0 0.8em; text-indent: 2em; }}
  </style>
</head>
<body>
  <h1>{escape(title)}</h1>
  {''.join(body)}
</body>
</html>
"""
    nav = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol><li><a href="content.xhtml">{escape(title)}</a></li></ol>
  </nav>
</body>
</html>
"""
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:dcterms="http://purl.org/dc/terms/">
    <dc:identifier id="book-id">{book_id}</dc:identifier>
    <dc:title>{escape(title)}</dc:title>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">{modified}</meta>
  </metadata>
  <manifest>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="content"/>
  </spine>
</package>
"""
    container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""
    part_output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(part_output, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.xhtml", content, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)

token = mineru_token()
total_pages, parts = split_pdf()
emit(f"STATUS=PDF 已拆成 {len(parts)} 个 MinerU 分段")
result_dir = temp_dir / "mineru_results"
result_dir.mkdir(parents=True, exist_ok=True)
markdown_by_name = {}
done_pages_before = 0
for batch_start in range(0, len(parts), MAX_FILES_PER_BATCH):
    batch = parts[batch_start:batch_start + MAX_FILES_PER_BATCH]
    emit(f"STATUS=正在申请 MinerU 上传链接：第 {batch_start + 1}-{batch_start + len(batch)} 段")
    batch_id, upload_urls = apply_for_uploads(token, batch)
    for part, upload_url in zip(batch, upload_urls):
        emit(f"STATUS=正在上传 MinerU 分段：第 {part['start']}-{part['end']} 页")
        upload_file(upload_url, part["path"])
    done_urls = poll_batch(token, batch_id, batch, total_pages, done_pages_before)
    for part in batch:
        data_id = part["name"].removesuffix(".pdf")
        emit(f"STATUS=正在下载 MinerU 结果：第 {part['start']}-{part['end']} 页")
        markdown_by_name[data_id] = download_full_md(done_urls[data_id], result_dir)
    done_pages_before += sum(part["pages"] for part in batch)

emit("PROGRESS=90")
emit("STATUS=正在合并 MinerU Markdown")
ordered_md = [markdown_for_md(markdown_by_name[part["name"].removesuffix(".pdf")]) for part in parts]
merged_markdown = merge_md_chunks(ordered_md)
ordered_text = [markdown_for_text(markdown_by_name[part["name"].removesuffix(".pdf")]) for part in parts]
merged_text = merge_text_chunks(ordered_text)
if output_format == "md" and not merged_markdown.strip():
    fail("MinerU 没有解析出可用 Markdown")
if output_format != "md" and not merged_text.strip():
    fail("MinerU 没有解析出可用文本")

if output_format == "txt":
    part_output.write_text(merged_text, encoding="utf-8")
elif output_format == "md":
    part_output.write_text(merged_markdown, encoding="utf-8")
else:
    markdown_to_epub(merged_text)
PY
  CHILD_PID=$!
  print "CHILD_PID=$CHILD_PID"
  wait "$CHILD_PID"
  STATUS=$?
  CHILD_PID=""

  if (( STATUS != 0 )); then
    print "STATUS=MinerU 精准解析失败，详情见下方日志"
    exit "$STATUS"
  fi

  if [[ ! -s "$PART" ]]; then
    print -u2 "ERROR=输出生成失败"
    exit 1
  fi

  mv "$PART" "$OUTPUT"
  print "PROGRESS=100"
  print "OUTPUT_PATH=$OUTPUT"
  if [[ "$FORMAT" == "txt" ]]; then
    print "STATUS=MinerU TXT 生成完成"
  elif [[ "$FORMAT" == "md" ]]; then
    print "STATUS=MinerU Markdown 生成完成"
  else
    print "STATUS=MinerU EPUB 生成完成"
  fi
  exit 0
fi

NEEDS_OCR=1
if [[ -n "$GS_BIN" ]]; then
  print "PHASE=DETECT"
  print "STATUS=正在检查 PDF 是否已有可用文字层"
  "$GS_BIN" -q -dBATCH -dNOPAUSE \
    -sDEVICE=txtwrite \
    -sOutputFile="$SIDECAR" \
    "$INPUT" &
  CHILD_PID=$!
  print "CHILD_PID=$CHILD_PID"
  wait "$CHILD_PID"
  STATUS=$?
  CHILD_PID=""

  if (( STATUS == 0 )) && [[ -s "$SIDECAR" ]]; then
    TEXT_CHECK="$("$PYTHON_BIN" - "$SIDECAR" "${TOTAL_PAGES:-0}" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
try:
    pages = max(1, int(sys.argv[2]))
except ValueError:
    pages = 1

readable = sum(
    1 for char in text
    if char.isalnum() or "\u3400" <= char <= "\u9fff"
)
minimum = max(120, pages * 15)
print(f"TEXT_CHARS={readable}")
print(f"TEXT_THRESHOLD={minimum}")
print("TEXT_LAYER=YES" if readable >= minimum else "TEXT_LAYER=NO")
PY
)"
    print "$TEXT_CHECK"
    if [[ "$TEXT_CHECK" == *"TEXT_LAYER=YES"* ]]; then
      NEEDS_OCR=0
      print "STATUS=检测到已有可用文字层，跳过 OCR，直接使用现有文字"
    else
      print "STATUS=未检测到足够文字层，准备进行本地 OCR"
    fi
  else
    print "STATUS=文字层检测失败，准备进行本地 OCR"
  fi
else
  print "STATUS=未找到 Ghostscript，无法检测文字层，准备进行本地 OCR"
fi

if (( NEEDS_OCR == 1 )); then
  print "PHASE=OCR"
  print "STATUS=正在使用 OCRmyPDF / Tesseract 识别 PDF 文字"
  "$OCR_BIN" -v 1 \
    --redo-ocr \
    --language "$LANGUAGE" \
    --rotate-pages \
    --oversample 300 \
    --sidecar "$SIDECAR" \
    --output-type pdf \
    "$INPUT" "$OCR_PDF" &
  CHILD_PID=$!
  print "CHILD_PID=$CHILD_PID"
  wait "$CHILD_PID"
  STATUS=$?
  CHILD_PID=""

  if (( STATUS != 0 )); then
    print -u2 "ERROR=OCRmyPDF 返回错误代码 $STATUS"
    exit "$STATUS"
  fi
fi

if [[ ! -s "$SIDECAR" ]]; then
  print -u2 "ERROR=没有提取到文字"
  exit 1
fi

print "PROGRESS=82"

if [[ "$FORMAT" == "txt" ]]; then
  print "PHASE=TXT"
  print "STATUS=正在整理 OCR 文字为 TXT"
  "$PYTHON_BIN" - "$SIDECAR" "$PART" <<'PY'
from pathlib import Path
import sys

sidecar = Path(sys.argv[1])
output = Path(sys.argv[2])
text = sidecar.read_text(encoding="utf-8", errors="replace")
text = text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n")
pages = [page.strip() for page in text.split("\f")]
pages = [page for page in pages if page]
result = "\n\n".join(pages).rstrip() + "\n"
if not result.strip():
    raise SystemExit("No readable text found")
output.write_text(result, encoding="utf-8")
PY
elif [[ "$FORMAT" == "md" ]]; then
  print "PHASE=MD"
  print "STATUS=正在整理 OCR 文字为 Markdown"
  "$PYTHON_BIN" - "$SIDECAR" "$PART" "$INPUT" <<'PY'
from pathlib import Path
import sys

sidecar = Path(sys.argv[1])
output = Path(sys.argv[2])
input_pdf = Path(sys.argv[3])
title = input_pdf.stem.replace("_", " ")
text = sidecar.read_text(encoding="utf-8", errors="replace")
text = text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n")
pages = [page.strip() for page in text.split("\f")]
pages = [page for page in pages if page]
body = "\n\n".join(pages).rstrip()
result = f"# {title}\n\n{body}\n"
if not body:
    raise SystemExit("No readable text found")
output.write_text(result, encoding="utf-8")
PY
else
  print "PHASE=EPUB"
  print "STATUS=正在生成可调字体 EPUB"
  "$PYTHON_BIN" - "$SIDECAR" "$PART" "$INPUT" <<'PY'
from datetime import datetime, timezone
from html import escape
from pathlib import Path
import re
import sys
import uuid
import zipfile

sidecar = Path(sys.argv[1])
output = Path(sys.argv[2])
input_pdf = Path(sys.argv[3])
title = input_pdf.stem.replace("_", " ")
text = sidecar.read_text(encoding="utf-8", errors="replace")
text = text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n")

def join_lines(lines):
    paragraphs = []
    current = ""
    for raw in lines:
        line = re.sub(r"\s+", " ", raw).strip()
        if not line:
            if current:
                paragraphs.append(current)
                current = ""
            continue
        if not current:
            current = line
            continue
        if re.search(r"[A-Za-z0-9]$", current) and re.match(r"^[A-Za-z0-9]", line):
            current += " " + line
        else:
            current += line
    if current:
        paragraphs.append(current)
    return paragraphs

pages = [page for page in text.split("\f") if page.strip()]
body = []
for page_number, page in enumerate(pages, 1):
    paragraphs = join_lines(page.splitlines())
    if not paragraphs:
        continue
    body.append(f'<section class="page" id="page-{page_number}">')
    for paragraph in paragraphs:
        body.append(f"<p>{escape(paragraph)}</p>")
    body.append("</section>")

if not body:
    raise SystemExit("No readable text found")

book_id = "book-" + uuid.uuid4().hex
modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
content = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <title>{escape(title)}</title>
  <style>
    body {{ margin: 0; padding: 0 4%; line-height: 1.55; }}
    h1 {{ text-align: center; margin: 2em 0; }}
    p {{ margin: 0 0 0.8em; text-indent: 2em; }}
    .page {{ break-before: page; page-break-before: always; }}
  </style>
</head>
<body>
  <h1>{escape(title)}</h1>
  {''.join(body)}
</body>
</html>
"""

nav = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol><li><a href="content.xhtml">{escape(title)}</a></li></ol>
  </nav>
</body>
</html>
"""

opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:dcterms="http://purl.org/dc/terms/">
    <dc:identifier id="book-id">{book_id}</dc:identifier>
    <dc:title>{escape(title)}</dc:title>
    <dc:language>zh-CN</dc:language>
    <meta property="dcterms:modified">{modified}</meta>
  </metadata>
  <manifest>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="content"/>
  </spine>
</package>
"""

container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    archive.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("OEBPS/content.xhtml", content, compress_type=zipfile.ZIP_DEFLATED)
    archive.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
PY
fi

if [[ ! -s "$PART" ]]; then
  print -u2 "ERROR=输出生成失败"
  exit 1
fi

mv "$PART" "$OUTPUT"
print "PROGRESS=100"
print "OUTPUT_PATH=$OUTPUT"
if [[ "$FORMAT" == "txt" ]]; then
  print "STATUS=TXT 生成完成"
elif [[ "$FORMAT" == "md" ]]; then
  print "STATUS=Markdown 生成完成"
else
  print "STATUS=EPUB 生成完成"
fi
