#!/usr/bin/env bats
# Behavioural tests for scripts/dump.
#
# Strategy:
#   - Project root is a tmpdir with a minimal .dock.yml.
#   - `docker` is shimmed via a PATH-prepended stub: it records its argv to a
#     log file and exits with success or controlled failure.
#   - cwd is the tmp project root before invoking dump.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DUMP="$PLUGIN_ROOT/scripts/dump"

  TMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'ccdock-dump')"
  PROJECT="$TMP/project"
  mkdir -p "$PROJECT/tmp"

  cat > "$PROJECT/.dock.yml" <<EOF
project_name: demoapp
base_host: dev.localhost
db_name: demoapp_development
db_user: postgres
db_service: postgres
dump_path: tmp/dock-dump.sql.gz
EOF

  # Stub docker on PATH. The stub records its argv + stdin to LOG_FILE.
  STUB_DIR="$TMP/bin"
  mkdir -p "$STUB_DIR"
  LOG_FILE="$TMP/docker.log"
  export LOG_FILE

  cd "$PROJECT"
}

teardown() {
  [ -n "$TMP" ] && rm -rf "$TMP"
}

# Helper: install a docker stub with the given behaviour for the `ps` subcommand.
# $1 = ps_mode: "running" emits a JSON line; "absent" emits nothing.
install_docker_stub() {
  local ps_mode="$1"
  cat > "$STUB_DIR/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$LOG_FILE"
if [ "\$1" = "compose" ] && [ "\$2" = "ps" ]; then
  if [ "$ps_mode" = "running" ]; then
    echo '{"Service":"postgres","State":"running"}'
    exit 0
  else
    exit 0
  fi
fi
if [ "\$1" = "compose" ] && [ "\$2" = "exec" ]; then
  # pg_dump stub — emit some bytes so gzip downstream has input.
  echo "fake sql dump"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUB_DIR/docker"
  export PATH="$STUB_DIR:$PATH"
}

@test "dump fails when main postgres service is not running" {
  install_docker_stub absent
  run "$DUMP"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "isn't running"
}

@test "dump invokes pg_dump --no-owner --no-acl when postgres is running" {
  install_docker_stub running
  run "$DUMP"
  [ "$status" -eq 0 ]
  # The compose exec line should reach our docker stub log with the expected flags.
  grep -E "compose exec .* pg_dump --no-owner --no-acl -U postgres demoapp_development" "$LOG_FILE"
}

@test "dump writes a gzip output at the configured dump_path" {
  install_docker_stub running
  run "$DUMP"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/tmp/dock-dump.sql.gz" ]
}

@test "dump aborts when .dock.yml is missing in the cwd tree" {
  rm "$PROJECT/.dock.yml"
  install_docker_stub running
  run "$DUMP"
  [ "$status" -ne 0 ]
}
