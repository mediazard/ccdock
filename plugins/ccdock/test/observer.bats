#!/usr/bin/env bats
# Behavioural tests for scripts/observer (the captain-side UserPromptSubmit hook).
#
# Strategy:
#   - HOME redirected to per-test tmpdir → inbox + cursor live in a sandbox.
#   - cwd is a tmp captain dir (no .dock/slug, so observer is allowed to run).
#   - Worker-self-exit case creates .dock/slug in cwd.
#
# Runtime: bats-core. Requires jq on PATH.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  OBSERVER="$PLUGIN_ROOT/scripts/observer"

  TMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'ccdock-observer')"
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/docks/inbox"

  CAPTAIN_DIR="$TMP/captain"
  mkdir -p "$CAPTAIN_DIR"
  cd "$CAPTAIN_DIR"
}

teardown() {
  [ -n "$TMP" ] && rm -rf "$TMP"
}

# Helper: write a single-line event into an inbox file (appending).
write_event() {
  local slug="$1" ts="$2" event="$3" msg="${4:-}"
  printf '{"ts":"%s","slug":"%s","event":"%s","hook":"Notification","message":"%s"}\n' \
    "$ts" "$slug" "$event" "$msg" >> "$HOME/.claude/docks/inbox/$slug.jsonl"
}

@test "exits 0 silently when no inbox dir exists" {
  rm -rf "$HOME/.claude/docks/inbox"
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits 0 silently when inbox is empty" {
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emits a question event tagged for captain context" {
  write_event sc-1 2026-05-14T10:00:00Z question 'need approval'
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '<ccdock-worker-events count="1">'
  echo "$output" | grep -q 'sc-1 (2026-05-14T10:00:00Z): need approval'
  echo "$output" | grep -q '</ccdock-worker-events>'
}

@test "subsequent run with no new events is silent (cursor advanced)" {
  write_event sc-1 2026-05-14T10:00:00Z question 'first'
  run "$OBSERVER"
  [ "$status" -eq 0 ]

  run "$OBSERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "newer question after cursor is surfaced" {
  write_event sc-1 2026-05-14T10:00:00Z question 'first'
  "$OBSERVER" >/dev/null
  write_event sc-1 2026-05-14T10:05:00Z idle ''
  write_event sc-1 2026-05-14T10:10:00Z question 'second'

  run "$OBSERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'sc-1 (2026-05-14T10:10:00Z): second'
  ! echo "$output" | grep -q 'first'
}

@test "only question events are surfaced — idle is ignored" {
  write_event sc-1 2026-05-14T10:00:00Z idle 'finished thinking'
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "multiple docks emit as separate lines under a single block" {
  write_event sc-1 2026-05-14T10:00:00Z question 'A'
  write_event happy-otter 2026-05-14T10:01:00Z question 'B'

  run "$OBSERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'count="2"'
  echo "$output" | grep -q 'sc-1.*A'
  echo "$output" | grep -q 'happy-otter.*B'
}

@test "worker session (.dock/slug present) self-exits silently" {
  write_event sc-1 2026-05-14T10:00:00Z question 'should not appear'
  mkdir -p .dock && echo 'sc-test' > .dock/slug

  run "$OBSERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox file with non-slug name is skipped (defence in depth)" {
  printf '{"ts":"2026-05-14T10:00:00Z","slug":"BAD","event":"question","hook":"Notification","message":"x"}\n' \
    > "$HOME/.claude/docks/inbox/BAD_NAME.jsonl"
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cursor file is created if missing and survives empty inbox" {
  write_event sc-1 2026-05-14T10:00:00Z question 'X'
  run "$OBSERVER"
  [ -f "$HOME/.claude/docks/captain-cursor.json" ]
  grep -q 'sc-1' "$HOME/.claude/docks/captain-cursor.json"
}

@test "corrupted cursor json is tolerated (treated as empty)" {
  echo 'not json{' > "$HOME/.claude/docks/captain-cursor.json"
  write_event sc-1 2026-05-14T10:00:00Z question 'Y'
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'sc-1.*Y'
}

@test "message with quotes does not corrupt output" {
  write_event sc-1 2026-05-14T10:00:00Z question 'why "this" route'
  run "$OBSERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'why .this. route'
}
