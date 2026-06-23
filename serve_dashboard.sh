#!/usr/bin/env bash
# serve_dashboard.sh — Serve the long-read sequencing dashboard locally over HTTP.
#
# WHY YOU NEED THIS
#   The dashboard's "All Variants" tab uses DuckDB-WASM to query a Parquet
#   sidecar via HTTP range requests. Browsers disallow range requests on
#   file:// URLs, so opening als_dashboard.html by double-clicking it will
#   make the All-Variants tab fail to load. This script wraps Python's
#   built-in http.server to give DuckDB the HTTP backend it needs.
#
# USAGE
#   ./serve_dashboard.sh              # serves the current dir on a free port
#   ./serve_dashboard.sh 8765         # serves on a specific port
#   ./serve_dashboard.sh --dir /path  # serves a specific directory
#   ./serve_dashboard.sh --no-open    # don't try to open the browser
#
# REQUIREMENTS
#   python3 (any recent version — http.server is in the stdlib)
#
# WHAT IT SERVES
#   The script serves the directory it's run from (or --dir). Place both
#   files in that directory:
#     - als_dashboard.html     (or whatever --output you used)
#     - als_variants.parquet   (the sidecar — see the generator script's
#                               --parquet-output flag)
#
# REMOTE EC2 NOTE
#   If you're running this on the EC2 box that did the WGS analysis, you'll
#   need to tunnel the port back to your laptop:
#     ssh -L 8765:localhost:8765 ubuntu@your-ec2-host
#   then open http://localhost:8765/als_dashboard.html on your laptop.

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
# Default DIR: the directory the user invoked the script from. This is the
# most intuitive — `cd <dashboard dir>; ./serve_dashboard.sh` serves the
# dashboard sitting right next to it. Override with --dir if needed.
PORT=""
DIR="$(pwd)"
OPEN_BROWSER=true

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            DIR="$2"; shift 2 ;;
        --no-open)
            OPEN_BROWSER=false; shift ;;
        --help|-h)
            sed -n '2,30p' "$0"; exit 0 ;;
        [0-9]*)
            PORT="$1"; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

# ── Sanity checks ───────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found in PATH." >&2
    echo "       Install Python 3, then re-run this script." >&2
    exit 1
fi

if [[ ! -d "$DIR" ]]; then
    echo "ERROR: directory not found: $DIR" >&2
    exit 1
fi

# Warn if expected files are missing — better to know now than after the
# server is up and the user is staring at a 404.
HTML_COUNT=$(find "$DIR" -maxdepth 1 -name '*.html' 2>/dev/null | wc -l | tr -d ' ')
PARQUET_COUNT=$(find "$DIR" -maxdepth 1 -name '*.parquet' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$HTML_COUNT" == "0" ]]; then
    echo "WARNING: no .html files found in $DIR" >&2
fi
if [[ "$PARQUET_COUNT" == "0" ]]; then
    echo "WARNING: no .parquet files found in $DIR — the All-Variants tab won't load." >&2
fi

# ── Pick a free port if none given ──────────────────────────────────────────
if [[ -z "$PORT" ]]; then
    # Ask the kernel for a free port — bind to 0, then read back the port. This
    # is more reliable than picking a random number and hoping nothing's there.
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
fi

URL="http://localhost:${PORT}/"

# ── Locate the dashboard file to suggest to the user / open in the browser ──
DASHBOARD_HTML=""
for candidate in longread_dashboard.html dashboard.html; do
    if [[ -f "$DIR/$candidate" ]]; then
        DASHBOARD_HTML="$candidate"
        break
    fi
done
# Fallback: pick the first .html in the folder
if [[ -z "$DASHBOARD_HTML" && "$HTML_COUNT" != "0" ]]; then
    DASHBOARD_HTML=$(basename "$(find "$DIR" -maxdepth 1 -name '*.html' | head -n1)")
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " Long-read sequencing dashboard local server"
echo "════════════════════════════════════════════════════════════════════"
echo " Serving:  $DIR"
echo " Port:     $PORT"
if [[ -n "$DASHBOARD_HTML" ]]; then
    echo " Open:     ${URL}${DASHBOARD_HTML}"
else
    echo " Open:     ${URL}"
fi
echo ""
echo " Stop with Ctrl-C."
echo "════════════════════════════════════════════════════════════════════"
echo ""

# ── Open the browser (best-effort) ──────────────────────────────────────────
if [[ "$OPEN_BROWSER" == "true" && -n "$DASHBOARD_HTML" ]]; then
    # Give the server a moment to come up before opening.
    (
        sleep 1
        if [[ "$(uname)" == "Darwin" ]]; then
            open "${URL}${DASHBOARD_HTML}" >/dev/null 2>&1 || true
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "${URL}${DASHBOARD_HTML}" >/dev/null 2>&1 || true
        fi
    ) &
fi

# ── Serve ───────────────────────────────────────────────────────────────────
# Bind explicitly to 127.0.0.1 so we don't accidentally expose the WGS data
# to the network. If you need LAN access, change to 0.0.0.0 deliberately.
#
# We DON'T use `python3 -m http.server` directly because its handler doesn't
# honor HTTP Range requests, and DuckDB-WASM relies on Range to do partial
# reads of the Parquet sidecar. Without Range, the browser ends up downloading
# the entire (potentially 200-400 MB) file before any query can run.
#
# Instead, we subclass SimpleHTTPRequestHandler with a tiny inline Python
# program that adds Range support, plus a couple of cache-control + CORS
# headers that DuckDB-WASM prefers.

cd "$DIR"
exec python3 -c '
import sys, os, re
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

class RangeHandler(SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler with HTTP Range support.

    DuckDB-WASM range-reads the parquet sidecar to avoid downloading hundreds
    of MB up front. Standard SimpleHTTPRequestHandler ignores the Range header
    and returns the full file, defeating the entire point. This handler parses
    Range: bytes=START-END and serves a 206 Partial Content with the slice.
    Only single-range requests are supported (DuckDB only sends those).
    """

    def end_headers(self):
        # Allow range scans + tell the browser these files can be cached.
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_GET(self):
        # Strip query string so range scanning still works behind a router.
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().do_GET()

        range_header = self.headers.get("Range")
        if not range_header:
            return super().do_GET()

        # Parquet readers use two range styles:
        #   bytes=START-END  → byte START through byte END (inclusive)
        #   bytes=START-     → byte START to end of file
        #   bytes=-SUFFIX    → last SUFFIX bytes (used to grab the parquet footer)
        file_size = os.path.getsize(path)
        m1 = re.match(r"bytes=(\d+)-(\d*)$", range_header)
        m2 = re.match(r"bytes=-(\d+)$", range_header)
        if m1:
            start = int(m1.group(1))
            end = int(m1.group(2)) if m1.group(2) else file_size - 1
        elif m2:
            suffix_len = int(m2.group(1))
            start = max(0, file_size - suffix_len)
            end = file_size - 1
        else:
            return super().do_GET()
        end = min(end, file_size - 1)

        if start >= file_size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return

        length = end - start + 1
        ctype = self.guess_type(path)
        try:
            with open(path, "rb") as f:
                f.seek(start)
                data = f.read(length)
            self.send_response(206)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            # Browser bailed mid-stream — harmless, just stop.
            pass

port = int(sys.argv[1])
ThreadingHTTPServer(("127.0.0.1", port), RangeHandler).serve_forever()
' "$PORT"
