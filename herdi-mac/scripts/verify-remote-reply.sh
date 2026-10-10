#!/bin/bash
# Deterministic acceptance for the mac app's remote-reply wire path — the exact
# hop an Allow/Trust/Deny click rides (runSSH → ssh → remote login shell →
# herdr pane send-text). No approval dialog needed, so no waiting on bwrap to
# fail: a throwaway shell pane echoes the probe back, and execution of the
# trailing command proves text+Enter arrived as one submission.
#
# The ssh invocation mirrors RelayConnection.runSSH (same options, same
# single-argument quoting) so a green here means the app's wire path is sound.
#
# Run on the mac:  herdi-mac/scripts/verify-remote-reply.sh [remote-host] [herdr-bin]
set -uo pipefail

REMOTE="${1:-tanglei.azshentong.com}"
HERDR_BIN="${2:-herdr}"
MARK="HERDI_REPLY_PROBE_$(date +%s)"
TMP_TAB_LABEL="HERDI-PROBE"

fail() { echo "FAIL: $1"; cleanup; exit 1; }

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ClearAllForwardings=yes "$REMOTE")
# RelayConnection.shlexQuoted: single-quote every argument.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

cleanup() {
    [ -n "${TAB_ID:-}" ] && "${SSH[@]}" "$(q "$HERDR_BIN")" $(q tab) $(q close) $(q "$TAB_ID") >/dev/null 2>&1
}

# 1. A throwaway shell pane: one tab in the first workspace, ours to close.
WS="$("${SSH[@]}" "$(q "$HERDR_BIN")" $(q workspace) $(q list) 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspaces"][0]["workspace_id"])')" \
    || fail "cannot list workspaces on $REMOTE"
"${SSH[@]}" "$(q "$HERDR_BIN")" $(q tab) $(q create) $(q --workspace) $(q "$WS") $(q --label) $(q "$TMP_TAB_LABEL") >/dev/null \
    || fail "cannot create probe tab"
TAB_ID="$("${SSH[@]}" "$(q "$HERDR_BIN")" $(q pane) $(q list) 2>/dev/null \
    | python3 -c '
import json,sys
panes = json.load(sys.stdin)["result"]["panes"]
shell = [p for p in panes if not p.get("agent")]
print(shell[-1]["pane_id"] if shell else "")')" \
    || fail "cannot resolve probe pane id"
[ -n "$TAB_ID" ] || fail "no shell pane found after tab create"
sleep 1

# 2. The probe: one argument carrying spaces AND the submit newline, exactly
#    what replyPayload wraps a word reply in.
"${SSH[@]}" "$(q "$HERDR_BIN")" $(q pane) $(q send-text) $(q "$TAB_ID") $(q "echo $MARK")$'\n' >/dev/null \
    || fail "send-text failed"
sleep 2

# 3. Assert the trailing newline executed the command inside the pane.
OUT="$("${SSH[@]}" "$(q "$HERDR_BIN")" $(q pane) $(q read) $(q "$TAB_ID") $(q --lines) $(q 10) $(q --source) $(q visible) 2>/dev/null)"
echo "$OUT" | grep -q "$MARK" || fail "probe command did not execute — submit keystroke lost"
# Sent twice? One submission only: exactly one occurrence.
N="$(echo "$OUT" | grep -c "$MARK")"
[ "$N" = "1" ] || fail "probe ran $N times (expected 1)"

cleanup
echo "PASS: remote reply path intact ($REMOTE, pane $TAB_ID, probe executed exactly once)"
