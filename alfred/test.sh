#!/bin/bash
# Runs search.sh against a throwaway database and checks what Alfred would get.
set -euo pipefail
cd "$(dirname "$0")"

export HOLT_DB="$(mktemp -d)/holt.db"
now=$(($(date +%s) * 1000))
sqlite3 "$HOLT_DB" "
CREATE TABLE clips (id INTEGER PRIMARY KEY, text TEXT, kind INTEGER, created_at INTEGER, pinned INTEGER,
                    deleted INTEGER, copied_by TEXT, copied_on TEXT);
CREATE TABLE peers (id TEXT PRIMARY KEY, name TEXT NOT NULL);
INSERT INTO peers VALUES ('mbp', 'MacBook Pro');
INSERT INTO clips VALUES
  (1, 'old pinned note', 0, $now - 90000000, 1, 0, NULL, NULL),
  (2, 'https://holt.snowztech.com', 1, $now - 120000, 0, 0, 'mbp', 'MacBook Pro'),
  (3, '  it''s 100% done' || char(10) || 'second line', 0, $now - 5000, 0, 0, 'me', 'This Mac'),
  (4, 'deleted clip', 0, $now, 0, 1, NULL, NULL),
  (5, '100 percent', 0, $now, 0, 0, NULL, NULL);"

titles() { ./search.sh "$1" | jq -r '[.items[].title] | join("|")'; }
check() { [[ "$1" == "$2" ]] || { echo "expected '$2', got '$1'" >&2; exit 1; }; }

check "$(titles "")" "old pinned note|100 percent|it's 100% done|https://holt.snowztech.com"
check "$(titles "DONE it's")" "it's 100% done"
check "$(titles "100%")" "it's 100% done"
check "$(titles "nothing here")" "No clips match"
check "$(./search.sh holt | jq -r '.items[0].subtitle')" "Copied 2 min ago on MacBook Pro"
check "$(./search.sh holt | jq -r '.items[0].quicklookurl')" "https://holt.snowztech.com"
check "$(./search.sh done | jq -r '.items[0].subtitle')" "Copied just now"
check "$(./search.sh done | jq -r '.items[0].arg')" "$(printf "  it's 100%% done\nsecond line")"
check "$(./search.sh old | jq -r '.items[0].subtitle')" "Pinned. Copied yesterday"
check "$(HOLT_DB=/nonexistent ./search.sh x | jq -r '.items[0].title')" "Holt isn't installed"
echo "alfred: ok"
