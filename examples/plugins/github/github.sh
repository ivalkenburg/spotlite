#!/bin/sh
# Searches repositories through GitHub's HTTP API. The query is the last argument.
# Unauthenticated searches are limited to ten a minute; a token in $GITHUB_TOKEN or in
# the file "$SPOTLITE_PLUGIN_DATA/token" raises that and finds private repositories.

query="$1"
configuration="${SPOTLITE_CONFIG:-}"
if [ -z "$configuration" ]; then configuration='{}'; fi
organization="$(printf '%s' "$configuration" | jq -r '.organization // ""')"
limit="$(printf '%s' "$configuration" | jq -r '(.resultLimit // 20) | floor')"
if [ -n "$organization" ]; then query="$query org:$organization"; fi
token="${GITHUB_TOKEN:-$(cat "$SPOTLITE_PLUGIN_DATA/token" 2>/dev/null)}"

response="$(curl -sS --max-time 8 -G "https://api.github.com/search/repositories" \
  --data-urlencode "q=$query" -d "per_page=$limit" \
  -H "Accept: application/vnd.github+json" \
  ${token:+-H "Authorization: Bearer $token"})" || exit $?

printf '%s' "$response" |
jq '
  def short: if . >= 1000000 then "\((. / 100000 | floor) / 10)m"
             elif . >= 1000 then "\((. / 100 | floor) / 10)k" else "\(.)" end;
  if (.items | type) == "array" then {
    items: [.items[] | {
      id: .full_name,
      title: .full_name,
      subtitle: .language,
      accessory: "★ \(.stargazers_count | short)",
      icon: (if .private then "lock" elif .fork then "arrow.triangle.branch" else "book.closed" end),
      action: {type: "open", url: .html_url}
    }]
  } else {
    items: [{title: (.message // "GitHub did not answer"), icon: "exclamationmark.triangle"}]
  } end'
