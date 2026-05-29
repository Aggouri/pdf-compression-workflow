#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") BASE_DIR ORIGINALS_DIR COMPRESSED_DIR WORKFLOW_NAME

Arguments:
  BASE_DIR
      Base workflow directory.

      The script expects/creates:
        BASE_DIR/incoming
        BASE_DIR/failed

  ORIGINALS_DIR
      Directory where the uncompressed original PDFs are moved after
      successful compression.

  COMPRESSED_DIR
      Directory where compressed PDFs are written.

      This can be anywhere, including a directory consumed by another app,
      service, or container.

  WORKFLOW_NAME
      Unique workflow name.

      Used to create a per-workflow lock and make notifications identifiable.

Example:
  $(basename "$0") "\$HOME/PDFs/workflow-a" "\$HOME/PDFs/originals/workflow-a" "\$HOME/PDFs/compressed/workflow-a" "workflow-a"
EOF
}

if [ "$#" -ne 4 ]; then
  echo "Error: expected exactly 4 arguments, got $#." >&2
  echo >&2
  usage
  exit 2
fi

BASE="$1"
ORIGINALS="$2"
COMPRESSED="$3"
WORKFLOW_NAME="$4"

case "$WORKFLOW_NAME" in
  *[!a-zA-Z0-9_-]*)
    echo "Error: WORKFLOW_NAME may only contain letters, numbers, underscores, and hyphens." >&2
    exit 2
    ;;
esac

INCOMING="${BASE}/incoming"
FAILED="${BASE}/failed"
LOCKDIR="/tmp/pdf-compression.${WORKFLOW_NAME}.lock"

# Minimum age in seconds before touching a PDF.
# 300 = 5 minutes.
MIN_AGE_SECONDS=300

TMP_DIR=""

mkdir -p "$INCOMING" "$COMPRESSED" "$ORIGINALS" "$FAILED"

notify_error() {
  local title="$1"
  local message="$2"

  /usr/bin/osascript - "$title" "$message" <<'OSA' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
OSA
}

cleanup() {
  rmdir "$LOCKDIR" 2>/dev/null || true

  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

on_unexpected_error() {
  local exit_code="$?"

  notify_error \
    "PDF compression crashed" \
    "Workflow '${WORKFLOW_NAME}' exited unexpectedly. Check ${BASE}/${WORKFLOW_NAME}-compression-error.log"

  exit "$exit_code"
}

fail_file() {
  local file="$1"
  local unique_filename="$2"
  local reason="$3"

  echo "Failed: ${reason}: ${unique_filename}"

  if [ -f "$file" ]; then
    if ! mv "$file" "$FAILED/$unique_filename"; then
      echo "Failed: could not move file to failed directory: $file -> $FAILED/$unique_filename"
      notify_error \
        "PDF compression failed badly" \
        "Workflow '${WORKFLOW_NAME}': ${reason}, and could not move file to failed folder: ${unique_filename}"
      return 0
    fi
  fi

  notify_error \
    "PDF compression failed" \
    "Workflow '${WORKFLOW_NAME}': ${reason}. File moved to failed: ${unique_filename}"
}

is_file_stable() {
  local file="$1"

  # If another process has it open, leave it alone.
  if lsof "$file" >/dev/null 2>&1; then
    return 1
  fi

  local size1 size2
  size1=$(stat -f "%z" "$file")
  sleep 5
  size2=$(stat -f "%z" "$file")

  [[ "$size1" == "$size2" ]]
}

# Prevent overlapping runs for this workflow.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pdf-compression.${WORKFLOW_NAME}.XXXXXX")"

trap cleanup EXIT
trap on_unexpected_error ERR

while IFS= read -r -d '' file; do
  filename="$(basename "$file")"
  stem="${filename%.*}"
  ext="${filename##*.}"

  timestamp=$(date +"%Y-%m-%d_%H%M%S")
  random_suffix=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-6)

  unique_stem="${timestamp}_${stem}_${random_suffix}"
  unique_filename="${unique_stem}.${ext}"

  modified_epoch=$(stat -f "%m" "$file")
  now_epoch=$(date +%s)
  age=$(( now_epoch - modified_epoch ))

  if [ "$age" -lt "$MIN_AGE_SECONDS" ]; then
    echo "Skipping too-recent file: $filename age=${age}s"
    continue
  fi

  if ! is_file_stable "$file"; then
    echo "Skipping unstable/open file: $filename"
    continue
  fi

  tmp="$TMP_DIR/${unique_stem}.compressed.tmp.pdf"
  output="$COMPRESSED/${unique_stem}.pdf"

  echo "Compressing: $filename -> ${output}"

  if gs -sDEVICE=pdfwrite \
    -dCompatibilityLevel=1.4 \
    -dWriteObjStms=false \
    -dWriteXRefStm=false \
    -dPDFSETTINGS=/ebook \
    -dNOPAUSE -dBATCH \
    -sOutputFile="$tmp" \
    "$file"; then

    if [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      fail_file "$file" "$unique_filename" "empty compressed output"
      continue
    fi

    in_pages=$(pdfinfo "$file" | awk '/^Pages:/ {print $2}' || true)
    out_pages=$(pdfinfo "$tmp" | awk '/^Pages:/ {print $2}' || true)

    if [ -z "$in_pages" ] || [ -z "$out_pages" ]; then
      rm -f "$tmp"
      fail_file "$file" "$unique_filename" "could not determine page count"
      continue
    fi

    if [ "$in_pages" != "$out_pages" ]; then
      rm -f "$tmp"
      fail_file "$file" "$unique_filename" "page count mismatch input=${in_pages} output=${out_pages}"
      continue
    fi

    if ! cp "$tmp" "$output"; then
      rm -f "$tmp"
      fail_file "$file" "$unique_filename" "could not write compressed output"
      continue
    fi

    rm -f "$tmp"

    if ! mv "$file" "$ORIGINALS/$unique_filename"; then
      rm -f "$output"
      fail_file "$file" "$unique_filename" "could not move original to originals directory"
      continue
    fi

    echo "Created: $output"
    echo "Original saved as: $ORIGINALS/$unique_filename"

  else
    rm -f "$tmp"
    fail_file "$file" "$unique_filename" "Ghostscript compression error"
    continue
  fi
done < <(find "$INCOMING" -maxdepth 1 -type f -iname "*.pdf" -print0)
