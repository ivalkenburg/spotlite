#!/bin/sh
# Searches repositories through GitHub's HTTP API. The query is the last argument.
# Unauthenticated searches are limited to ten a minute; a token in $GITHUB_TOKEN or in
# the file "$SPOTLITE_PLUGIN_DATA/token" raises that and finds private repositories.

query="$1"
token="${GITHUB_TOKEN:-$(cat "$SPOTLITE_PLUGIN_DATA/token" 2>/dev/null)}"

curl -sS --max-time 8 -G "https://api.github.com/search/repositories" \
  --data-urlencode "q=$query" -d per_page=20 \
  -H "Accept: application/vnd.github+json" \
  ${token:+-H "Authorization: Bearer $token"} |
jq '
  if (.items | type) == "array" then {
    items: [.items[] | {
      id: .full_name,
      title: .full_name,
      subtitle: ("★ \(.stargazers_count)" + (if .language then " · " + .language else "" end)),
      icon: (if .private then "lock" elif .fork then "arrow.triangle.branch" else "book.closed" end),
      action: {type: "open", url: .html_url}
    }]
  } else {
    items: [{title: (.message // "GitHub did not answer"), icon: "exclamationmark.triangle"}]
  } end'
