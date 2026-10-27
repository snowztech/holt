#!/bin/bash
# Alfred Script Filter: prints Alfred's JSON for the clips matching "$1".
# Same rules as Store::search in holt-core: every word must appear, pinned first, then newest.
set -euo pipefail

db="${HOLT_DB:-$HOME/Library/Application Support/Holt/holt.db}"

if [[ ! -f "$db" ]]; then
  echo '{"items":[{"title":"Holt isn'\''t installed","subtitle":"Get it at holt.snowztech.com","valid":false}]}'
  exit 0
fi

# sqlite3 takes no bound parameters here, so words are escaped into literals.
where=""
read -ra words <<<"${1:-}"
for w in ${words[@]+"${words[@]}"}; do
  w=${w//\\/\\\\}
  w=${w//%/\\%}
  w=${w//_/\\_}
  w=${w//\'/\'\'}
  where+=" AND text LIKE '%$w%' ESCAPE '\\'"
done

sqlite3 -readonly "$db" "
WITH found AS (
  SELECT text, kind, pinned, created_at,
         ltrim(text, ' ' || char(9, 10, 13)) AS body,
         (strftime('%s', 'now') * 1000 - created_at) / 1000 AS age,
         CASE WHEN copied_by IN (SELECT id FROM peers) THEN copied_on END AS device
  FROM clips WHERE deleted = 0$where
  ORDER BY pinned DESC, created_at DESC LIMIT 50
),
items AS (
  SELECT json_object(
    'title', substr(body, 1, instr(body || char(10), char(10)) - 1),
    'subtitle', CASE WHEN pinned THEN 'Pinned. ' ELSE '' END || 'Copied ' ||
      CASE WHEN age < 60 THEN 'just now'
           WHEN age < 3600 THEN (age / 60) || ' min ago'
           WHEN age < 86400 THEN (age / 3600) || ' hr ago'
           WHEN age < 172800 THEN 'yesterday'
           ELSE (age / 86400) || ' days ago' END ||
      coalesce(' on ' || device, ''),
    'arg', text,
    'text', json_object('copy', text, 'largetype', text),
    'quicklookurl', CASE WHEN kind = 1 THEN trim(text) END,
    'mods', json_object('cmd', json_object('arg', text, 'subtitle', 'Copy without pasting'))
  ) AS item FROM found
)
SELECT json_object('items', CASE WHEN count(*) = 0
  THEN json_array(json_object('title', 'No clips match', 'valid', json('false')))
  ELSE json_group_array(json(item)) END)
FROM items;
"
