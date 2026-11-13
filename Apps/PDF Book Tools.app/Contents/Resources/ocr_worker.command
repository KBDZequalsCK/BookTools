#!/bin/zsh
set -u

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

INPUT="${1:-}"
LANGUAGE="${2:-}"
OUTPUT="${3:-}"
PART="${OUTPUT}.part"
CHILD_PID=""

cleanup() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
  rm -f "$PART"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -z "$INPUT" || -z "$LANGUAGE" || -z "$OUTPUT" ]]; then
  print -u2 "ERROR=参数不足"
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

QPDF_BIN=""
for candidate in "$(command -v qpdf 2>/dev/null || true)" /usr/local/bin/qpdf /opt/homebrew/bin/qpdf; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    QPDF_BIN="$candidate"
    break
  fi
done

if [[ -z "$OCR_BIN" || -z "$TESSERACT_BIN" ]]; then
  print -u2 "ERROR=找不到 OCRmyPDF 或 Tesseract"
  exit 127
fi

if [[ ! -f "$INPUT" ]]; then
  print -u2 "ERROR=输入 PDF 不存在"
  exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$PART"
print "PHASE=OCR"
print "PART_PATH=$PART"
print "STATUS=正在识别 PDF 文字"
if [[ -n "$QPDF_BIN" ]]; then
  TOTAL_PAGES="$("$QPDF_BIN" --show-npages "$INPUT" 2>/dev/null || true)"
  if [[ "$TOTAL_PAGES" == <-> ]]; then
    print "TOTAL_PAGES=$TOTAL_PAGES"
  fi
fi

"$OCR_BIN" -v 1 -l "$LANGUAGE" --redo-ocr --rotate-pages --oversample 300 --output-type pdf "$INPUT" "$PART" &
CHILD_PID=$!
print "CHILD_PID=$CHILD_PID"
wait "$CHILD_PID"
STATUS=$?
CHILD_PID=""

if (( STATUS != 0 )); then
  print -u2 "ERROR=OCRmyPDF 返回错误代码 $STATUS"
  exit "$STATUS"
fi

if [[ ! -s "$PART" ]]; then
  print -u2 "ERROR=OCRmyPDF 没有生成有效输出"
  exit 1
fi

mv "$PART" "$OUTPUT"
print "PROGRESS=100"
print "OUTPUT_PATH=$OUTPUT"
print "STATUS=OCR 完成"
