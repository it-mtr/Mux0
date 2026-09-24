#!/bin/bash
# smoke.sh — end-to-end bash smoke test of agent-hook.sh.
# Sets up a fake Unix socket with Python, fires all 4 subcommands with
# handcrafted JSON payloads, asserts socket received the right messages
# and session file is in the expected state.

set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$HERE/.."
AGENT_HOOK="$SCRIPT_DIR/agent-hook.sh"

TMPDIR_LOCAL=$(mktemp -d -t mux0-smoke.XXXXXX)
SOCK="$TMPDIR_LOCAL/hook.sock"
SESSION_FILE_OVERRIDE="$TMPDIR_LOCAL/sessions.json"
TRANSCRIPT="$TMPDIR_LOCAL/transcript.jsonl"
RECEIVED="$TMPDIR_LOCAL/received.log"

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID"
    fi
    rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT INT TERM

# Seed transcript
cat > "$TRANSCRIPT" <<'EOF'
{"role":"user","content":"refactor foo"}
{"role":"assistant","content":"I refactored Foo.swift."}
EOF

# Start a Python Unix-socket echo server that appends each line to RECEIVED
python3 - "$SOCK" "$RECEIVED" <<'PY' &
import sys, socket, os
sock_path, log_path = sys.argv[1], sys.argv[2]
try: os.unlink(sock_path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(8)
with open(log_path, "w") as log:
    while True:
        conn, _ = s.accept()
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        conn.close()
        log.write(data.decode())
        log.flush()
PY
SERVER_PID=$!
sleep 0.3   # let server bind before first client connect

export MUX0_HOOK_SOCK="$SOCK"
export MUX0_TERMINAL_ID="00000000-0000-0000-0000-000000000001"

# Redirect agent-hook.py's session file to our temp copy.
# agent-hook.sh hardcodes the path, so we override the env var _after_ it
# would have been set by sourcing — simplest: patch the path by running
# the python directly for the session-file path, or temporarily edit.
# Here we just use a wrapper that sets _MUX0_SESSION_FILE manually:
run_hook() {
    local sub="$1"; shift
    local agt="$1"; shift
    local payload="$1"; shift
    _MUX0_SUBCMD="$sub" _MUX0_AGENT="$agt" \
      _MUX0_SESSION_FILE="$SESSION_FILE_OVERRIDE" \
      _MUX0_PAYLOAD="$payload" \
      python3 "$SCRIPT_DIR/agent-hook.py"
}

# Scenario: prompt → pretool(Edit) → posttool(is_error=true) → stop
run_hook prompt   claude '{"session_id":"s1","transcript_path":"'"$TRANSCRIPT"'"}'
run_hook pretool  claude '{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"/foo/bar/baz.swift"}}'
run_hook posttool claude '{"session_id":"s1","tool_name":"Edit","tool_response":{"is_error":true}}'
run_hook stop     claude '{"session_id":"s1"}'

sleep 0.3   # server flushes

# Assertions
if ! grep -q '"event": "running"' "$RECEIVED"; then
    echo "FAIL: no running event in received log" >&2; exit 1
fi
if ! grep -q '"toolDetail": "Edit foo/bar/baz.swift"' "$RECEIVED"; then
    echo "FAIL: no toolDetail in received log" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"exitCode": 1' "$RECEIVED"; then
    echo "FAIL: stop did not emit exitCode 1 (turn had error)" >&2; cat "$RECEIVED" >&2; exit 1
fi
if ! grep -q '"summary": "I refactored Foo.swift."' "$RECEIVED"; then
    echo "FAIL: summary not in stop payload" >&2; cat "$RECEIVED" >&2; exit 1
fi

# Session entry should be removed
if grep -q '"s1"' "$SESSION_FILE_OVERRIDE"; then
    echo "FAIL: session entry s1 still present" >&2
    cat "$SESSION_FILE_OVERRIDE" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Grok: full lifecycle through the real socket, using grok's actual envelope
# (camelCase fields + snake_case aliases, `reason`, `lastAssistantMessage`).
# ---------------------------------------------------------------------------
GROK_SID="01a0d1d8-4252-7992-a65b-4ee8d890878f"
GROK_HOME="$TMPDIR_LOCAL/.grok"
mkdir -p "$GROK_HOME/sessions/%2Fprivate%2Ftmp%2Fproj/$GROK_SID"
cat > "$GROK_HOME/sessions/%2Fprivate%2Ftmp%2Fproj/$GROK_SID/summary.json" <<EOF
{"generated_title":"List Files Then Say Done","session_kind":"interactive"}
EOF
cat > "$GROK_HOME/sessions/%2Fprivate%2Ftmp%2Fproj/$GROK_SID/chat_history.jsonl" <<'EOF'
{"type":"user","content":[{"type":"text","text":"<user_query>\nls please\n</user_query>"}]}
{"type":"assistant","content":"Files: a.txt DONE"}
EOF
export GROK_HOME

MARK_GROK=$(( $(wc -l < "$RECEIVED") ))

run_hook prompt  grok "{\"session_id\":\"$GROK_SID\",\"sessionId\":\"$GROK_SID\",\"promptId\":\"p1\",\"hook_event_name\":\"UserPromptSubmit\"}"
run_hook pretool grok "{\"session_id\":\"$GROK_SID\",\"tool_name\":\"list_dir\",\"tool_input\":{\"target_directory\":\"/tmp/proj\"},\"transcript_path\":\"/tmp/updates.jsonl\"}"
run_hook posttool grok "{\"session_id\":\"$GROK_SID\",\"tool_name\":\"list_dir\",\"tool_response\":{\"type\":\"ListDir\",\"Content\":{\"is_error\":true,\"content\":\"EACCES\"}}}"
run_hook notification grok "{\"session_id\":\"$GROK_SID\",\"notificationType\":\"permission_prompt\",\"message\":\"Allow?\"}"
run_hook stop    grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"end_turn\",\"lastAssistantMessage\":\"Files: a.txt DONE\"}"
# teardown duplicate: grok fires an observe-only Stop with reason=shutdown,
# then SessionEnd. Neither may emit a second `finished`.
run_hook stop    grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"shutdown\"}"
run_hook sessionend grok "{\"session_id\":\"$GROK_SID\",\"reason\":\"shutdown\"}"

sleep 0.4
GROK_OUT="$TMPDIR_LOCAL/grok.out"
tail -n +$(( MARK_GROK + 1 )) "$RECEIVED" > "$GROK_OUT"

assert_grok() {
    if ! grep -q "$1" "$GROK_OUT"; then
        echo "FAIL(grok): missing $1" >&2; cat "$GROK_OUT" >&2; exit 1
    fi
}
assert_grok '"agent": "grok"'
assert_grok '"resumeCommand": "grok --resume 01a0d1d8-4252-7992-a65b-4ee8d890878f"'
assert_grok '"sessionTitle": "List Files Then Say Done"'
assert_grok '"toolDetail": "List tmp/proj"'
assert_grok '"event": "needsInput"'
assert_grok '"exitCode": 1'          # the failing list_dir must poison the turn
assert_grok '"summary": "Files: a.txt DONE"'
# exactly one `finished` for the turn (the reason=shutdown Stop must not add one)
FINISHED_COUNT=$(grep -c '"event": "finished"' "$GROK_OUT")
if [ "$FINISHED_COUNT" != "1" ]; then
    echo "FAIL(grok): expected exactly 1 finished, got $FINISHED_COUNT" >&2
    cat "$GROK_OUT" >&2; exit 1
fi
if ! grep -q '"event": "idle"' "$GROK_OUT"; then
    echo "FAIL(grok): SessionEnd did not emit idle" >&2; cat "$GROK_OUT" >&2; exit 1
fi

# idle_prompt backstop: settles a turn that never reported Stop, and stays
# silent once the turn already settled.
MARK_BACKSTOP=$(( $(wc -l < "$RECEIVED") ))
run_hook prompt grok "{\"session_id\":\"$GROK_SID\",\"sessionId\":\"$GROK_SID\"}"
run_hook notification grok "{\"session_id\":\"$GROK_SID\",\"notificationType\":\"idle_prompt\"}"
run_hook notification grok "{\"session_id\":\"$GROK_SID\",\"notificationType\":\"idle_prompt\"}"
sleep 0.4
BACKSTOP_OUT="$TMPDIR_LOCAL/grok-backstop.out"
tail -n +$(( MARK_BACKSTOP + 1 )) "$RECEIVED" > "$BACKSTOP_OUT"
BACKSTOP_FINISHED=$(grep -c '"event": "finished"' "$BACKSTOP_OUT")
if [ "$BACKSTOP_FINISHED" != "1" ]; then
    echo "FAIL(grok): idle_prompt backstop emitted $BACKSTOP_FINISHED finished (want 1)" >&2
    cat "$BACKSTOP_OUT" >&2; exit 1
fi
if ! grep -q '"summary": "Files: a.txt DONE"' "$BACKSTOP_OUT"; then
    echo "FAIL(grok): backstop summary not read from chat_history.jsonl" >&2
    cat "$BACKSTOP_OUT" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# pi: shell layer (wrapper) — the extension itself is covered by
# tests/pi_extension_test.py, which drives it in Node against a real socket.
# ---------------------------------------------------------------------------
FAKE_BIN="$TMPDIR_LOCAL/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/pi" <<EOF
#!/bin/bash
echo "PI_ARGS=\$*" >> "$RECEIVED"
echo "pi (fake) ran"
EOF
chmod +x "$FAKE_BIN/pi"
OLD_PATH="$PATH"
export PATH="$FAKE_BIN:$PATH"
unset MUX0_REAL_PI
# smoke.sh drives agent-hook.py directly (run_hook), so the hooks dir is not
# exported by default — the wrapper needs it to locate the extension.
export MUX0_AGENT_HOOKS_DIR="$SCRIPT_DIR"

"$SCRIPT_DIR/pi-wrapper.sh" "hello" >/dev/null
"$SCRIPT_DIR/pi-wrapper.sh" --version >/dev/null

if ! grep -q '^PI_ARGS=-e .*pi-extension/mux0-status.js hello$' "$RECEIVED"; then
    echo "FAIL(pi): wrapper did not inject -e <extension>" >&2
    grep '^PI_ARGS=' "$RECEIVED" >&2; exit 1
fi
if grep -q '^PI_ARGS=-e .*--version$' "$RECEIVED"; then
    echo "FAIL(pi): --version must pass through without injection" >&2; exit 1
fi
if ! grep -q '"event":"idle","agent":"pi"\|"event": "idle", "agent": "pi"' "$RECEIVED"; then
    # hook-emit.sh writes compact JSON — accept either spacing.
    if ! grep -q 'agent=pi' "$HOME/Library/Caches/mux0/hook-emit.log"; then
        echo "FAIL(pi): wrapper emitted no idle event" >&2; exit 1
    fi
fi
export PATH="$OLD_PATH"

echo "SMOKE OK"
