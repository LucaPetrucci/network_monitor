#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *"SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS"* ]]; then
  printf '1\n'
  exit 0
fi

if [[ " $* " == *" INSERT INTO "* ]]; then
  printf '%s\n' "$*" >>"${MOCK_MYSQL_LOG:?}"
fi
