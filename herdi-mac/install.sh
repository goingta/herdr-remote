#!/bin/bash
# Install dist/Herdi.app into /Applications with rollback guards.
#
# Guards (each exits 1 unless --force), both for real failure modes seen
# on 2026-10-11:
# - stale dist: a source file newer than the dist binary means the bundle
#   predates the current sources — installing ships yesterday's code
#   ("what landed in /Applications was the old dist" cost a debugging
#   round once; verify the binary mtime, every time).
# - newer installed: the app in /Applications was built after dist was,
#   so installing rolls it back (the goat-head status icon was lost to
#   exactly this when a build from an older source tree went over it).
# A dirty workspace is reported but not blocking: it means dist may carry
# work no commit records, which is context, not a stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERDI_INSTALL_SRC:-$SCRIPT_DIR/dist/Herdi.app}"
DST="${HERDI_INSTALL_DST:-/Applications/Herdi.app}"
FORCE="${1:-}"

die() { echo "✗ $*" >&2; exit 1; }

FORCE=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) die "unknown argument: $arg (only --force is supported)" ;;
    esac
done

[ -d "$SRC" ] || die "no $SRC — run ./build.sh first"

version() { defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?"; }
mtime() { stat -f "%m" "$1/Contents/MacOS/Herdi" 2>/dev/null || echo 0; }

SRC_BIN="$SRC/Contents/MacOS/Herdi"

# Everything under the target dir counts as "source" for staleness except
# build outputs and the generated project: a project.yml or entitlement
# edited after the last build must also block an install.
stale_files=$(find "$SCRIPT_DIR" -type f -newer "$SRC_BIN" \
    -not -path "*/.build/*" -not -path "*/dist/*" -not -path "*/Herdi.xcodeproj/*" 2>/dev/null)
stale=$(printf '%s\n' "$stale_files" | grep -c . || true)
if [ "$stale" != "0" ] && [ -z "$FORCE" ]; then
    printf '%s\n' "$stale_files" | head -5 | sed 's/^/  newer: /'
    die "$stale source file(s) are newer than dist — run ./build.sh first (or re-run with --force)"
fi

if [ -d "$DST" ]; then
    echo "dist      : v$(version "$SRC") built $(date -r "$(mtime "$SRC")" "+%F %T")"
    echo "installed : v$(version "$DST") built $(date -r "$(mtime "$DST")" "+%F %T")"
    if [ "$(mtime "$DST")" -gt "$(mtime "$SRC")" ] && [ -z "$FORCE" ]; then
        die "$DST is NEWER than dist — installing would roll it back (re-run with --force to proceed)"
    fi
else
    echo "dist      : v$(version "$SRC") built $(date -r "$(mtime "$SRC")" "+%F %T") (fresh install)"
fi

dirty=$(git -C "$SCRIPT_DIR" status --porcelain -- . 2>/dev/null | wc -l | tr -d ' ')
[ "$dirty" != "0" ] && echo "note: herdi-mac/ has $dirty uncommitted file(s) — dist may carry work no commit records"

echo "▸ Quitting Herdi…"
osascript -e 'tell application "Herdi" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    pgrep -x Herdi >/dev/null || break
    sleep 1
done
echo "▸ Installing to ${DST}…"
# Mirror, not copy-into: cp -R onto an existing directory NESTS the bundle
# (seen here: /Applications/Herdi.app/Herdi.app, the real app never
# updated). Trailing-slash rsync semantics are unambiguous, -a keeps the
# stamps the newer-installed guard compares, and --delete drops files the
# new build no longer has.
rsync -a --delete "$SRC/" "$DST/"
echo "▸ Launching…"
open "$DST"
echo "✓ Installed v$(version "$DST")"
