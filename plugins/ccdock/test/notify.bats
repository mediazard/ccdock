#!/usr/bin/env bats
# Behavioural tests for scripts/notify (the Claude Code hook handler).
#
# Strategy:
#   - HOME is redirected to a per-test tmpdir → inbox writes land in a sandbox.
#   - cwd is a tmpdir; we create / omit the .dock/slug marker to control bail-out.
#   - jq + date are required on PATH (they are on dev macOS/Linux already).
#
# Runtime: bats-core (`brew install bats-core` or `apt install bats`).

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NOTIFY="$PLUGIN_ROOT/scripts/notify"

  TMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'ccdock-notify')"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  WORKSPACE="$TMP/workspace"
  mkdir -p "$WORKSPACE"
  cd "$WORKSPACE"
}

teardown() {
  [ -n "$TMP" ] && rm -rf "$TMP"
}

@test "notify exits 0 silently when no .dock/slug marker exists" {
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  # No inbox dir is created when bailing.
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "Notification hook writes a question event to the inbox" {
  mkdir -p .dock && echo 'sc-1' > .dock/slug
  run bash -c "echo '{\"message\":\"need approval\"}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  inbox="$HOME/.claude/docks/inbox/sc-1.jsonl"
  [ -f "$inbox" ]
  grep -q '"event":"question"' "$inbox"
  grep -q '"slug":"sc-1"' "$inbox"
  grep -q '"hook":"Notification"' "$inbox"
  grep -q '"message":"need approval"' "$inbox"
}

@test "Stop hook writes an idle event" {
  mkdir -p .dock && echo 'sc-2' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Stop"
  [ "$status" -eq 0 ]
  grep -q '"event":"idle"' "$HOME/.claude/docks/inbox/sc-2.jsonl"
  grep -q '"hook":"Stop"' "$HOME/.claude/docks/inbox/sc-2.jsonl"
}

@test "empty stdin is tolerated (defaults to '{}')" {
  mkdir -p .dock && echo 'sc-3' > .dock/slug
  run bash -c "'$NOTIFY' Notification < /dev/null"
  [ "$status" -eq 0 ]
  inbox="$HOME/.claude/docks/inbox/sc-3.jsonl"
  [ -f "$inbox" ]
  # Message should be empty string when jq has nothing to extract.
  grep -q '"message":""' "$inbox"
}

@test "empty slug marker file causes a silent exit (no inbox write)" {
  mkdir -p .dock && : > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "multiple invocations append (not overwrite) inbox lines" {
  mkdir -p .dock && echo 'sc-4' > .dock/slug
  bash -c "echo '{}' | '$NOTIFY' Notification"
  bash -c "echo '{}' | '$NOTIFY' Stop"
  inbox="$HOME/.claude/docks/inbox/sc-4.jsonl"
  [ "$(wc -l < "$inbox" | tr -d ' ')" = "2" ]
}

@test "slug containing '..' path traversal is rejected silently" {
  mkdir -p .dock && echo '../evil' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "slug containing '/' is rejected silently" {
  mkdir -p .dock && echo 'foo/bar' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "slug containing uppercase characters is rejected silently" {
  mkdir -p .dock && echo 'SC-5' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "slug starting with '-' is rejected silently" {
  mkdir -p .dock && echo '-sc-6' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "slug ending with '-' is rejected silently" {
  mkdir -p .dock && echo 'sc-6-' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "slug with embedded shell metacharacter ';' is rejected silently" {
  mkdir -p .dock && echo 'sc;rm' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "multi-line slug file: only first line is read and bad chars rejected" {
  mkdir -p .dock && printf 'BAD/slug\nsc-good\n' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "slug longer than 63 chars is rejected silently" {
  long_slug=$(printf 'a%.0s' {1..64})
  mkdir -p .dock && echo "$long_slug" > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/docks/inbox" ]
}

@test "valid slug with trailing whitespace is accepted (whitespace stripped)" {
  mkdir -p .dock && printf 'sc-7\n' > .dock/slug
  run bash -c "echo '{}' | '$NOTIFY' Notification"
  [ "$status" -eq 0 ]
  inbox="$HOME/.claude/docks/inbox/sc-7.jsonl"
  [ -f "$inbox" ]
  grep -q '"slug":"sc-7"' "$inbox"
}
