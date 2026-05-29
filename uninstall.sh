#!/bin/bash
set -euo pipefail

# PlistBuddy is used to read the installed LaunchAgent configuration.
PLISTBUDDY="/usr/libexec/PlistBuddy"

usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") --name NAME [--remove-logs]

Required arguments:
  -n, --name NAME
      Workflow name to uninstall.

      This must match the name used during install:
        ./install.sh --name NAME ...

Optional arguments:
  --remove-logs
      Also remove this workflow's log files.

      The base directory is read from the LaunchAgent plist, so you do not
      need to provide it manually.

  -h, --help
      Show this help message.

Examples:
  $(basename "$0") --name workflow-a

  $(basename "$0") -n workflow-b

  $(basename "$0") -n workflow-a --remove-logs
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"

  if [ -z "$value" ]; then
    echo "Error: ${option} requires a value." >&2
    echo >&2
    usage
    exit 2
  fi

  case "$value" in
    --*|-*)
      echo "Error: ${option} requires a value, got another option: ${value}" >&2
      echo >&2
      usage
      exit 2
      ;;
  esac
}

read_plist_value() {
  local plist="$1"
  local key_path="$2"

  "$PLISTBUDDY" -c "Print ${key_path}" "$plist" 2>/dev/null || true
}

# --- Defaults ---
WORKFLOW_NAME=""
REMOVE_LOGS=false
LOGS_STATUS="not requested"

# --- Parse named arguments ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name|-n)
      require_value "$1" "${2:-}"
      WORKFLOW_NAME="$2"
      shift 2
      ;;
    --remove-logs)
      REMOVE_LOGS=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo >&2
      usage
      exit 2
      ;;
  esac
done

# --- Validate required arguments ---
if [ -z "$WORKFLOW_NAME" ]; then
  echo "Error: missing required argument: --name / -n" >&2
  echo >&2
  usage
  exit 2
fi

# --- Validate workflow name ---
case "$WORKFLOW_NAME" in
  *[!a-zA-Z0-9_-]*)
    echo "Error: --name / -n may only contain letters, numbers, underscores, and hyphens." >&2
    exit 2
    ;;
esac

# --- launchd identifiers and paths ---
AGENT_LABEL="org.aggouri.pdf-compression.${WORKFLOW_NAME}"
AGENT_PATH="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
LOCKDIR="/tmp/pdf-compression.${WORKFLOW_NAME}.lock"

# --- Fail if the workflow does not exist ---
if [ ! -f "$AGENT_PATH" ]; then
  echo "Error: workflow does not exist:" >&2
  echo "  ${WORKFLOW_NAME}" >&2
  echo >&2
  echo "Expected LaunchAgent plist:" >&2
  echo "  ${AGENT_PATH}" >&2
  echo >&2
  echo "Nothing was uninstalled." >&2
  exit 1
fi

# --- Read installed configuration from LaunchAgent plist ---
BASE_PATH="$(read_plist_value "$AGENT_PATH" ":ProgramArguments:1")"
ORIGINALS_PATH="$(read_plist_value "$AGENT_PATH" ":ProgramArguments:2")"
COMPRESSED_PATH="$(read_plist_value "$AGENT_PATH" ":ProgramArguments:3")"
PLIST_WORKFLOW_NAME="$(read_plist_value "$AGENT_PATH" ":ProgramArguments:4")"

# --- Validate LaunchAgent shape ---
if [ -z "$BASE_PATH" ] || [ -z "$ORIGINALS_PATH" ] || [ -z "$COMPRESSED_PATH" ] || [ -z "$PLIST_WORKFLOW_NAME" ]; then
  echo "Error: LaunchAgent plist exists but does not contain the expected configuration." >&2
  echo >&2
  echo "LaunchAgent plist:" >&2
  echo "  ${AGENT_PATH}" >&2
  echo >&2
  echo "Expected ProgramArguments:" >&2
  echo "  0: script path" >&2
  echo "  1: base directory" >&2
  echo "  2: originals directory" >&2
  echo "  3: compressed output directory" >&2
  echo "  4: workflow name" >&2
  echo >&2
  echo "Nothing was uninstalled." >&2
  exit 1
fi

if [ "$PLIST_WORKFLOW_NAME" != "$WORKFLOW_NAME" ]; then
  echo "Error: LaunchAgent plist workflow name does not match requested workflow." >&2
  echo "  Requested: ${WORKFLOW_NAME}" >&2
  echo "  Found:     ${PLIST_WORKFLOW_NAME}" >&2
  echo >&2
  echo "Nothing was uninstalled." >&2
  exit 1
fi

echo "Uninstalling workflow:"
echo "  ${WORKFLOW_NAME}"
echo ""

echo "Configuration found in LaunchAgent:"
echo "  Base directory:              ${BASE_PATH}"
echo "  Originals directory:         ${ORIGINALS_PATH}"
echo "  Compressed output directory: ${COMPRESSED_PATH}"
echo ""

# --- Unload and remove LaunchAgent ---
echo "Unloading LaunchAgent:"
echo "  ${AGENT_PATH}"

launchctl unload "$AGENT_PATH" 2>/dev/null || true

echo "Removing LaunchAgent plist:"
echo "  ${AGENT_PATH}"

rm -f "$AGENT_PATH"

# --- Remove stale lock if present ---
if [ -d "$LOCKDIR" ]; then
  echo "Removing stale lock directory:"
  echo "  ${LOCKDIR}"

  rmdir "$LOCKDIR" 2>/dev/null || {
    echo "Warning: could not remove lock directory, maybe it is in use:"
    echo "  ${LOCKDIR}"
  }
fi

# --- Optionally remove logs ---
if [ "$REMOVE_LOGS" = true ]; then
  STDOUT_LOG="${BASE_PATH}/${WORKFLOW_NAME}-compression.log"
  STDERR_LOG="${BASE_PATH}/${WORKFLOW_NAME}-compression-error.log"

  echo "Removing logs:"
  echo "  ${STDOUT_LOG}"
  echo "  ${STDERR_LOG}"

  LOG_FILES_FOUND=false

  if [ -f "$STDOUT_LOG" ] || [ -f "$STDERR_LOG" ]; then
    LOG_FILES_FOUND=true
  fi

  rm -f "$STDOUT_LOG" "$STDERR_LOG"

  if [ "$LOG_FILES_FOUND" = true ]; then
    LOGS_STATUS="removed"
  else
    LOGS_STATUS="requested, but no log files existed"
  fi
else
  LOGS_STATUS="not removed because --remove-logs was not passed"
fi

echo ""
echo "✅ Uninstall complete."
echo ""
echo "Removed workflow:"
echo "  ${WORKFLOW_NAME}"
echo ""
echo "Logs:"
echo "  ${LOGS_STATUS}"
echo ""
echo "Not removed:"
echo "  - input folders"
echo "  - compressed output folders"
echo "  - originals folders"
echo "  - failed files"
echo ""
echo "That is intentional. This script only removes the LaunchAgent, lock, and logs when requested."
