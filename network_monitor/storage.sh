#!/usr/bin/env bash
# Shared storage selection. Source after setup.conf and SCRIPT_DIR are defined.
DB_BACKEND="${DB_BACKEND:-mariadb}"
case "$DB_BACKEND" in
  mariadb|influxdb) ;;
  *) echo "Error: unsupported DB_BACKEND: $DB_BACKEND" >&2; exit 1 ;;
esac
storage_python=python3
if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
  storage_python="$SCRIPT_DIR/.venv/bin/python3"
fi
export NM_RUN_ID NM_HOST

influx_write() {
  "$storage_python" "$SCRIPT_DIR/influx_store.py" write "$@"
}
