#!/bin/bash
set -euo pipefail

# launchd does not inherit the same PATH as an interactive shell.
# Include common Homebrew locations so dependency checks match runtime behavior.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") --name NAME --base-dir BASE_DIR --compressed-dir COMPRESSED_DIR --originals-dir ORIGINALS_DIR

Required arguments:
  -n, --name NAME
      Unique workflow name.

      Use a short identifier such as:
        workflow-a
        archive
        documents
        receipts

      This is used to create a separate LaunchAgent, lock, and notification label
      for each workflow.

  -b, --base-dir BASE_DIR
      Base workflow directory.

      The installer will configure the compression script to use:
        BASE_DIR/incoming
        BASE_DIR/failed

      PDFs should be written to:
        BASE_DIR/incoming

  -c, --compressed-dir COMPRESSED_DIR
      Directory where compressed PDFs will be written.

      This can be anywhere, including a directory consumed by another app,
      service, or container.

  -o, --originals-dir ORIGINALS_DIR
      Directory where uncompressed original PDFs will be moved after
      successful compression.

Optional arguments:
  -i, --interval SECONDS
      How often launchd should run the script.
      Default: 120

  -h, --help
      Show this help message.

Example:
  $(basename "$0") \\
    -n workflow-a \\
    -b "\$HOME/PDFs/workflow-a" \\
    -c "\$HOME/PDFs/compressed/workflow-a" \\
    -o "\$HOME/PDFs/originals/workflow-a"
EOF
}

check_dependencies() {
  local missing_commands=()
  local brew_packages=()

  # External dependencies used by the worker script and installer.
  # gs      -> ghostscript
  # pdfinfo -> poppler
  # The remaining commands are expected macOS system tools.
  for cmd in gs pdfinfo uuidgen lsof stat launchctl osascript; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")

      case "$cmd" in
        gs)
          brew_packages+=("ghostscript")
          ;;
        pdfinfo)
          brew_packages+=("poppler")
          ;;
      esac
    fi
  done

  if [ "${#missing_commands[@]}" -gt 0 ]; then
    echo "Error: missing required dependencies:" >&2
    echo >&2

    for cmd in "${missing_commands[@]}"; do
      echo "  - $cmd" >&2
    done

    echo >&2

    # Print only the Homebrew packages that are actually needed.
    if [ "${#brew_packages[@]}" -gt 0 ]; then
      local brew_install_command="brew install"
      local seen_packages=" "
      local package

      for package in "${brew_packages[@]}"; do
        case "$seen_packages" in
          *" $package "*)
            ;;
          *)
            brew_install_command="${brew_install_command} ${package}"
            seen_packages="${seen_packages}${package} "
            ;;
        esac
      done

      echo "Install the missing Homebrew dependencies with:" >&2
      echo >&2
      echo "  ${brew_install_command}" >&2
      echo >&2
    fi

    echo "Dependency notes:" >&2
    echo "  - 'gs' is provided by the Homebrew package 'ghostscript'." >&2
    echo "  - 'pdfinfo' is provided by the Homebrew package 'poppler'." >&2
    echo "  - 'uuidgen', 'lsof', 'stat', 'launchctl', and 'osascript' are normally provided by macOS." >&2

    local missing_system_commands=()
    local cmd

    for cmd in "${missing_commands[@]}"; do
      case "$cmd" in
        gs|pdfinfo)
          ;;
        *)
          missing_system_commands+=("$cmd")
          ;;
      esac
    done

    if [ "${#missing_system_commands[@]}" -gt 0 ]; then
      echo >&2
      echo "The following expected macOS system commands are missing or not in PATH:" >&2

      for cmd in "${missing_system_commands[@]}"; do
        echo "  - $cmd" >&2
      done

      echo >&2
      echo "Check your PATH or macOS command line tools installation." >&2
    fi

    echo >&2
    echo "After fixing the missing dependencies, rerun this installer." >&2

    exit 1
  fi
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

make_absolute_path() {
  local path="$1"

  case "$path" in
    /*)
      printf '%s\n' "$path"
      ;;
    ~)
      printf '%s\n' "$HOME"
      ;;
    ~/*)
      printf '%s/%s\n' "$HOME" "${path#~/}"
      ;;
    *)
      printf '%s/%s\n' "$PWD" "$path"
      ;;
  esac
}

# --- Defaults ---
RUN_INTERVAL=120

WORKFLOW_NAME=""
BASE_PATH=""
COMPRESSED_PATH=""
ORIGINALS_PATH=""

# --- Parse named arguments ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name|-n)
      require_value "$1" "${2:-}"
      WORKFLOW_NAME="$2"
      shift 2
      ;;
    --base-dir|-b)
      require_value "$1" "${2:-}"
      BASE_PATH="$2"
      shift 2
      ;;
    --compressed-dir|-c)
      require_value "$1" "${2:-}"
      COMPRESSED_PATH="$2"
      shift 2
      ;;
    --originals-dir|-o)
      require_value "$1" "${2:-}"
      ORIGINALS_PATH="$2"
      shift 2
      ;;
    --interval|-i)
      require_value "$1" "${2:-}"
      RUN_INTERVAL="$2"
      shift 2
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
missing_args=()

if [ -z "$WORKFLOW_NAME" ]; then
  missing_args+=("--name / -n")
fi

if [ -z "$BASE_PATH" ]; then
  missing_args+=("--base-dir / -b")
fi

if [ -z "$COMPRESSED_PATH" ]; then
  missing_args+=("--compressed-dir / -c")
fi

if [ -z "$ORIGINALS_PATH" ]; then
  missing_args+=("--originals-dir / -o")
fi

if [ "${#missing_args[@]}" -gt 0 ]; then
  echo "Error: missing required arguments:" >&2
  echo >&2

  for arg in "${missing_args[@]}"; do
    echo "  - $arg" >&2
  done

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

# --- Validate interval ---
case "$RUN_INTERVAL" in
  ''|*[!0-9]*)
    echo "Error: --interval / -i must be a positive integer number of seconds." >&2
    exit 2
    ;;
esac

if [ "$RUN_INTERVAL" -lt 10 ]; then
  echo "Error: --interval / -i is too low. Use at least 10 seconds." >&2
  exit 2
fi

# --- Normalize paths ---
BASE_PATH="$(make_absolute_path "$BASE_PATH")"
COMPRESSED_PATH="$(make_absolute_path "$COMPRESSED_PATH")"
ORIGINALS_PATH="$(make_absolute_path "$ORIGINALS_PATH")"

INCOMING_PATH="${BASE_PATH}/incoming"
FAILED_PATH="${BASE_PATH}/failed"

# --- Get absolute script path ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SCRIPT_PATH="${SCRIPT_DIR}/compress-pdfs.sh"

# --- launchd identifiers and paths ---
AGENT_LABEL="org.aggouri.pdf-compression.${WORKFLOW_NAME}"
AGENT_DIR="${HOME}/Library/LaunchAgents"
AGENT_PATH="${AGENT_DIR}/${AGENT_LABEL}.plist"

STDOUT_LOG="${BASE_PATH}/${WORKFLOW_NAME}-compression.log"
STDERR_LOG="${BASE_PATH}/${WORKFLOW_NAME}-compression-error.log"

# --- Validate dependencies ---
check_dependencies

# --- Validate worker script ---
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: compression script not found at:" >&2
  echo "  $SCRIPT_PATH" >&2
  exit 1
fi

if [ ! -x "$SCRIPT_PATH" ]; then
  echo "Error: compression script exists but is not executable:" >&2
  echo "  $SCRIPT_PATH" >&2
  echo >&2
  echo "Fix with:" >&2
  echo "  chmod +x \"$SCRIPT_PATH\"" >&2
  exit 1
fi

# --- Create required directories ---
# The worker also creates these, but the installer creates them first so
# WatchPaths points at an existing folder when the LaunchAgent is loaded.
mkdir -p "$INCOMING_PATH"
mkdir -p "$FAILED_PATH"
mkdir -p "$ORIGINALS_PATH"
mkdir -p "$COMPRESSED_PATH"
mkdir -p "$AGENT_DIR"

# --- Create the launchd Agent .plist file ---
echo "Creating LaunchAgent at: ${AGENT_PATH}"

cat <<EOF > "${AGENT_PATH}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_PATH}</string>
        <string>${BASE_PATH}</string>
        <string>${ORIGINALS_PATH}</string>
        <string>${COMPRESSED_PATH}</string>
        <string>${WORKFLOW_NAME}</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>WatchPaths</key>
    <array>
        <string>${INCOMING_PATH}</string>
    </array>

    <key>StartInterval</key>
    <integer>${RUN_INTERVAL}</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${STDOUT_LOG}</string>

    <key>StandardErrorPath</key>
    <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF

# --- Load and start the Agent ---
# Unload any existing version first so reinstalling updates the configuration.
launchctl unload "${AGENT_PATH}" 2>/dev/null || true

echo "Loading and starting the LaunchAgent..."
launchctl load "${AGENT_PATH}"

echo ""
echo "✅ Installation complete."
echo ""
echo "Workflow:"
echo "  ${WORKFLOW_NAME}"
echo ""
echo "LaunchAgent:"
echo "  ${AGENT_PATH}"
echo ""
echo "Compression script:"
echo "  ${SCRIPT_PATH}"
echo ""
echo "Input folder:"
echo "  ${INCOMING_PATH}"
echo ""
echo "Compressed output folder:"
echo "  ${COMPRESSED_PATH}"
echo ""
echo "Originals folder:"
echo "  ${ORIGINALS_PATH}"
echo ""
echo "Failed files folder:"
echo "  ${FAILED_PATH}"
echo ""
echo "Logs:"
echo "  ${STDOUT_LOG}"
echo "  ${STDERR_LOG}"
echo ""
echo "The script will run every ${RUN_INTERVAL} seconds and also when the input folder changes."
echo ""
echo "Important:"
echo "  Write PDFs to:"
echo "    ${INCOMING_PATH}"
echo ""
echo "  Compressed files will be written to:"
echo "    ${COMPRESSED_PATH}"
echo ""
echo "If something fails, you should receive a macOS notification and the original file will be moved to:"
echo "  ${FAILED_PATH}"
echo ""
echo "To install another independent workflow, rerun this installer with a different --name."
