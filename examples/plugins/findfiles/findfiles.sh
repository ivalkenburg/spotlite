#!/bin/sh
# Finds files whose name contains the query, under the configured folder. The action
# streams ("stream": true): each file is printed as its own JSON line the moment find
# reaches it, so the first ones show while find is still walking the folder. jq stops
# after 200 files, which also ends find. Hidden folders and ~/Library are skipped.

folder="$(printf '%s' "${SPOTLITE_CONFIG:-}" | jq -r '.folder // empty' 2>/dev/null)"
folder="${folder:-$HOME}"
# The query is matched literally, not as a pattern.
pattern="*$(printf '%s' "$1" | sed 's/[][*?\\]/\\&/g')*"

find "$folder" \( -name '.*' -o -path "$HOME/Library" -o -name node_modules \) -prune \
  -o -iname "$pattern" -print 2>/dev/null |
jq -n -R -c --unbuffered --arg home "$HOME" '
  limit(200; inputs) |
  (split("/") | last) as $name |
  {
    id: .,
    title: $name,
    subtitle: (.[0:(length - ($name | length) - 1)] | if startswith($home) then "~" + .[($home | length):] else . end),
    icon: .,
    action: {type: "open", url: .}
  }'
