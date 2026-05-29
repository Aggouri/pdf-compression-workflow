# PDF Compression Workflow (macOS only)

This project provides a workflow for automating the compression of PDF documents on macOS.

It is especially useful for scanned PDFs, which are often large, but it can process any PDF placed into the input folder.

The solution is a background script that watches an input folder, compresses PDFs with Ghostscript, verifies that the compressed file is valid, and then organises both the compressed and original files into separate destinations.

The complete workflow looks like this:

```text
Scanner, scan app, or PDF source
        ↓
 BASE_DIR/incoming
        ↓
 Compression script
        ↓
 COMPRESSED_DIR      (compressed PDFs)
 ORIGINALS_DIR       (original PDFs)
```

The workflow uses a macOS `launchd` agent to run the compression script automatically.

The compression script itself is generic and can be used with any scanner, application, service, or container that writes PDFs into the input folder.

## What it does

PDFs placed in `BASE_DIR/incoming` are processed automatically. The workflow:

1. waits until the PDF has finished being written and has remained unchanged for several minutes;
2. compresses it with Ghostscript;
3. verifies that the page count has not changed;
4. writes the compressed PDF to `COMPRESSED_DIR`;
5. moves the original PDF to `ORIGINALS_DIR`;
6. moves the PDF to `BASE_DIR/failed` if something goes wrong.

The script sends a macOS notification when a real failure occurs.

## Requirements

```bash
brew install ghostscript poppler
```

Also uses standard macOS tools: `launchctl`, `uuidgen`, `lsof`, `stat`, `osascript`, and `PlistBuddy`.

## Quick start

Make scripts executable:

```bash
chmod +x ./install.sh ./compress-pdfs.sh ./uninstall.sh
```

Run the installer with demo values:

```bash
./install.sh \
  --name demo \
  --base-dir "$HOME/pdf-workflow-demo/base" \
  --compressed-dir "$HOME/pdf-workflow-demo/out" \
  --originals-dir "$HOME/pdf-workflow-demo/backups"
```

This:
1. Creates `$HOME/pdf-workflow-demo/base`, `$HOME/pdf-workflow-demo/base/incoming`, and `$HOME/pdf-workflow-demo/base/failed` (if they do not exist)
2. Creates `$HOME/pdf-workflow-demo/out` (if it does not exist)
3. Creates `$HOME/pdf-workflow-demo/backups` (if it does not exist)
4. Installs (or replaces) a LaunchAgent with label `org.aggouri.pdf-compression.demo`, configured to run the workflow with the chosen paths

After this, scan or place a PDF file into `$HOME/pdf-workflow-demo/base/incoming` and let the workflow do its work. About 5 minutes later, you should see the compressed file in `$HOME/pdf-workflow-demo/out` and the original file in `$HOME/pdf-workflow-demo/backups`.

To uninstall, run:

```shell
./uninstall.sh --name demo --remove-logs
```

Then delete the demo-related directories:

```shell
rm -rf $HOME/pdf-workflow-demo
```

## Install

Make scripts executable:

```bash
chmod +x ./install.sh ./compress-pdfs.sh ./uninstall.sh
```

To install a workflow, run the installer script (`install.sh`).

Arguments:

```text
-n, --name             Unique workflow name
-b, --base-dir         Contains incoming/, failed/, and logs
-c, --compressed-dir   Destination for compressed PDFs
-o, --originals-dir    Destination for original PDFs
-i, --interval         Optional run interval in seconds, default: 120
```

During installation, the script creates the required folders if they do not already exist: `BASE_DIR`, `BASE_DIR/incoming`, `BASE_DIR/failed`, `COMPRESSED_DIR`, and `ORIGINALS_DIR`.

It also installs and loads a dedicated LaunchAgent, configures the workflow with your chosen paths, and starts automatic PDF processing in the background.

After installing, point your scanner or scan workflow to send files to:

```text
BASE_DIR/incoming
```

## Multiple workflows

Use a different name and folders for each workflow:

```bash
./install.sh \
  -n workflow-b \
  -b "$HOME/Scans/workflow-b" \
  -c "$HOME/Scans/compressed-workflow-b" \
  -o "$HOME/Scans/originals-workflow-b"
```

Each workflow gets its own LaunchAgent and lock.

LaunchAgent example:

```text
org.aggouri.pdf-compression.workflow-b
```

Lock example:

```text
/tmp/pdf-compression.workflow-b.lock
```

## Uninstall

```bash
./uninstall.sh -n workflow-a
```

Remove logs too:

```bash
./uninstall.sh -n workflow-a --remove-logs
```

Uninstalling does not delete input, compressed, originals, or failed folders.

## Logs

Logs are written to:

```text
BASE_DIR/<workflow-name>-compression.log
BASE_DIR/<workflow-name>-compression-error.log
```

Example:

```bash
tail -f "$HOME/Scans/workflow-a/workflow-a-compression.log"
```

## Notes

The default Ghostscript preset is `/ebook`.

The script waits at least 5 minutes before processing a new PDF, then checks that the file size is stable. This avoids processing half-written files.

Temporary files are written to a private macOS temp directory and cleaned up automatically by the script.
