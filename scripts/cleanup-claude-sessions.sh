#!/usr/bin/env bash
# Bulk-archive Claude Code (claude.ai/code) web sessions.
#
# Background:
#   When a PR backed by a Claude Code on the web session is merged, the
#   session is not cleaned up automatically. The web UI only supports
#   archiving one session at a time. This script paginates
#   /api/v1/sessions and POSTs to the per-session archive endpoint in
#   batches. Archive (not delete) is reversible from the UI's "Archived"
#   filter, so this is the safe-by-default bulk cleanup.
#
# Cookie handling (interactive):
#   The script needs your claude.ai session cookie. It will:
#     1. Use $CLAUDE_COOKIE / --cookie if provided.
#     2. Otherwise look it up from the OS keychain (macOS Keychain or
#        libsecret via secret-tool; falls back to a chmod 600 file under
#        $XDG_CONFIG_HOME if neither is available).
#     3. If nothing is stored, prompt you interactively with instructions
#        on how to extract sessionKey from your browser, then save what
#        you paste back into the keychain.
#     4. If the stored cookie no longer works (expired / logged out),
#        forget it and prompt again.
#
# Usage:
#   ./cleanup-claude-sessions.sh [options]
#
# Options:
#   --apply              Actually archive matched sessions. Without this
#                        flag the script only lists what it would do.
#   --match <pattern>    Only archive sessions whose title matches this
#                        grep -E pattern (case-insensitive).
#   --limit <n>          Stop after archiving N sessions.
#   --page-size <n>      Sessions per page (default: 100).
#   --delay <seconds>    Pause between archive calls (default: 0.25).
#   --cookie <value>     Cookie header value. Falls back to $CLAUDE_COOKIE,
#                        then to the keychain, then to an interactive prompt.
#   --api-base <url>     Override API base (default: https://claude.ai).
#   --forget             Wipe the cookie from the keychain and exit.
#   -h, --help           Show this help.

set -euo pipefail

API_BASE="https://claude.ai"
SESSIONS_PATH="/api/v1/sessions"
ARCHIVE_PATH_TEMPLATE="/api/v1/sessions/%s/archive"
KEYCHAIN_SERVICE="claude-code-cleanup-cookie"
FALLBACK_COOKIE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-cleanup/cookie"

APPLY=0
MATCH=""
LIMIT=0
PAGE_SIZE=100
DELAY=0.25
COOKIE_OVERRIDE="${CLAUDE_COOKIE:-}"
COOKIE=""
FORGET=0

usage() {
  awk '/^#!/ {next} /^[^#]/ {exit} {sub(/^# ?/,""); print}' "$0"
}

# ---------------------------------------------------------------------------
# Keychain helpers
# ---------------------------------------------------------------------------

keychain_load() {
  case "$(uname -s)" in
    Darwin)
      security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w 2>/dev/null && return 0
      ;;
    *)
      if command -v secret-tool >/dev/null 2>&1; then
        secret-tool lookup service "$KEYCHAIN_SERVICE" account "$USER" 2>/dev/null && return 0
      fi
      ;;
  esac
  if [[ -r "$FALLBACK_COOKIE_FILE" ]]; then
    cat "$FALLBACK_COOKIE_FILE"
    return 0
  fi
  return 1
}

keychain_save() {
  local cookie="$1"
  case "$(uname -s)" in
    Darwin)
      security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" -w "$cookie" -U >/dev/null
      return 0
      ;;
    *)
      if command -v secret-tool >/dev/null 2>&1; then
        printf '%s' "$cookie" | secret-tool store --label="Claude Code cleanup cookie" \
          service "$KEYCHAIN_SERVICE" account "$USER"
        return 0
      fi
      ;;
  esac
  mkdir -p "$(dirname "$FALLBACK_COOKIE_FILE")"
  ( umask 077 && printf '%s' "$cookie" > "$FALLBACK_COOKIE_FILE" )
  echo "[cleanup] saved cookie to $FALLBACK_COOKIE_FILE (mode 600)" >&2
}

keychain_forget() {
  case "$(uname -s)" in
    Darwin)
      security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" >/dev/null 2>&1 || true
      ;;
    *)
      if command -v secret-tool >/dev/null 2>&1; then
        secret-tool clear service "$KEYCHAIN_SERVICE" account "$USER" >/dev/null 2>&1 || true
      fi
      ;;
  esac
  rm -f "$FALLBACK_COOKIE_FILE"
}

# ---------------------------------------------------------------------------
# Interactive cookie prompt
# ---------------------------------------------------------------------------

print_cookie_instructions() {
  cat >&2 <<'INSTR'

  Need your claude.ai session cookie. To find it:

    1. Open  https://claude.ai/code  in your browser (signed in).
    2. Open DevTools  (Cmd+Option+I on macOS, Ctrl+Shift+I elsewhere).
    3. Chrome/Edge/Brave: Application tab -> Storage -> Cookies -> https://claude.ai
       Firefox:          Storage tab     -> Cookies -> https://claude.ai
       Safari:           Storage tab     -> Cookies -> claude.ai
    4. Find the row named  sessionKey  and copy its Value.

  Paste either the bare value  (sk-ant-sid01-...)
              or the full pair  (sessionKey=sk-ant-sid01-...)

INSTR
}

prompt_cookie_interactive() {
  if ! { [[ -t 0 ]] && [[ -t 2 ]]; }; then
    echo "error: no cookie available and not running on a TTY." >&2
    echo "       Set \$CLAUDE_COOKIE or pass --cookie '<value>'." >&2
    exit 1
  fi
  print_cookie_instructions
  local cookie=""
  while [[ -z "$cookie" ]]; do
    read -r -s -p "  Paste cookie value: " cookie
    echo >&2
  done
  if [[ "$cookie" != *=* ]]; then
    cookie="sessionKey=$cookie"
  fi
  printf '%s' "$cookie"
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

api_call() {
  # api_call <METHOD> <PATH> <OUT_FILE> -> prints HTTP status code on stdout.
  local method="$1" path="$2" out_file="$3"
  curl -sS -o "$out_file" -w '%{http_code}' \
    -X "$method" \
    -H "Cookie: $COOKIE" \
    -H "Accept: application/json" \
    -H "Content-Length: 0" \
    "$API_BASE$path"
}

cookie_works() {
  local tmp code
  tmp=$(mktemp)
  code=$(api_call GET "$SESSIONS_PATH?limit=1" "$tmp")
  rm -f "$tmp"
  [[ "$code" -ge 200 && "$code" -lt 300 ]]
}

ensure_cookie() {
  # 1) Explicit override (CLI / env) — never overwrite the keychain with it.
  if [[ -n "$COOKIE_OVERRIDE" ]]; then
    COOKIE="$COOKIE_OVERRIDE"
    if cookie_works; then return 0; fi
    echo "error: the cookie passed via --cookie / \$CLAUDE_COOKIE was rejected by claude.ai" >&2
    exit 1
  fi

  # 2) Keychain.
  if COOKIE="$(keychain_load)" && [[ -n "$COOKIE" ]]; then
    if cookie_works; then return 0; fi
    echo "[cleanup] stored cookie is expired or invalid; forgetting it." >&2
    keychain_forget
  fi

  # 3) Interactive prompt, up to 3 attempts.
  local attempts=0
  while (( attempts < 3 )); do
    COOKIE="$(prompt_cookie_interactive)"
    if cookie_works; then
      keychain_save "$COOKIE"
      echo "[cleanup] cookie stashed; future runs won't ask." >&2
      return 0
    fi
    echo "  That cookie didn't work. Make sure you copied the Value of 'sessionKey' from claude.ai." >&2
    attempts=$((attempts + 1))
  done
  echo "error: gave up after 3 attempts." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Sessions API
# ---------------------------------------------------------------------------

list_sessions() {
  local cursor=""
  while :; do
    local query="?limit=$PAGE_SIZE"
    [[ -n "$cursor" ]] && query="$query&cursor=$cursor"
    local tmp code body
    tmp=$(mktemp)
    code=$(api_call GET "$SESSIONS_PATH$query" "$tmp")
    if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
      cat "$tmp" >&2
      rm -f "$tmp"
      echo "error: GET sessions returned HTTP $code" >&2
      exit 1
    fi
    body=$(<"$tmp")
    rm -f "$tmp"
    echo "$body" | jq -c '(.sessions // .data // .items // [])[]'
    cursor=$(echo "$body" | jq -r '.next_cursor // .nextCursor // .next // .cursor // empty')
    [[ -z "$cursor" ]] && break
  done
}

archive_session() {
  local id="$1"
  local path; printf -v path "$ARCHIVE_PATH_TEMPLATE" "$id"
  local tmp code
  tmp=$(mktemp)
  code=$(api_call POST "$path" "$tmp")
  rm -f "$tmp"
  [[ "$code" -ge 200 && "$code" -lt 300 ]]
}

matches_filter() {
  [[ -z "$MATCH" ]] && return 0
  echo "$1" | grep -Eiq "$MATCH"
}

# ---------------------------------------------------------------------------
# Arg parsing & main
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --match) MATCH="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --page-size) PAGE_SIZE="$2"; shift 2 ;;
    --delay) DELAY="$2"; shift 2 ;;
    --cookie) COOKIE_OVERRIDE="$2"; shift 2 ;;
    --api-base) API_BASE="$2"; shift 2 ;;
    --forget) FORGET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

if [[ "$FORGET" -eq 1 ]]; then
  keychain_forget
  echo "[cleanup] forgot stored cookie."
  exit 0
fi

ensure_cookie

main() {
  echo "[cleanup] scanning sessions (apply=$APPLY, match='${MATCH:-*}')"
  local total=0 archived=0 failed=0
  while IFS= read -r session; do
    local id title is_archived
    id=$(echo "$session" | jq -r '.id // .uuid // empty')
    title=$(echo "$session" | jq -r '.title // .name // ""')
    is_archived=$(echo "$session" | jq -r '.archived // .is_archived // false')

    [[ -z "$id" ]] && continue
    [[ "$is_archived" == "true" ]] && continue
    matches_filter "$title" || continue

    total=$((total + 1))
    if [[ "$APPLY" -eq 0 ]]; then
      printf '[dry-run] would archive %s  %s\n' "$id" "$title"
    else
      if archive_session "$id"; then
        archived=$((archived + 1))
        printf '[cleanup] archived %s  %s\n' "$id" "$title"
      else
        failed=$((failed + 1))
        printf '[cleanup] FAILED   %s  %s\n' "$id" "$title" >&2
      fi
      sleep "$DELAY"
    fi

    if [[ "$LIMIT" -gt 0 && "$total" -ge "$LIMIT" ]]; then break; fi
  done < <(list_sessions)

  if [[ "$APPLY" -eq 0 ]]; then
    echo "[cleanup] dry-run: $total session(s) would be archived. Re-run with --apply."
  else
    echo "[cleanup] done. archived=$archived failed=$failed"
  fi
}

main
