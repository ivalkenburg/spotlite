#!/bin/sh
# Searches repositories through GitHub's HTTP API. The query is the last argument.
# Unauthenticated searches are limited to ten a minute. An access token raises that and
# finds private repositories: set one in Settings → Plugins → GitHub → Configure, where
# Spotlite keeps it in the Keychain and passes it in $SPOTLITE_CONFIG, or in $GITHUB_TOKEN.
# Earlier versions read "$SPOTLITE_PLUGIN_DATA/token"; paste that token into Settings.

query="$1"
configuration="${SPOTLITE_CONFIG:-}"
if [ -z "$configuration" ]; then configuration='{}'; fi
organization="$(printf '%s' "$configuration" | jq -r '.organization // ""')"
limit="$(printf '%s' "$configuration" | jq -r '(.resultLimit // 20) | floor')"
if [ -n "$organization" ]; then query="$query org:$organization"; fi
token="$(printf '%s' "$configuration" | jq -r '.token // ""')"
token="${token:-${GITHUB_TOKEN:-}}"

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
      action: {type: "open", url: .html_url},
      # ⌥↩ copies the link, as on any row that opens an address; ⌘K lists all of these.
      actions: [
        {title: "Copy Clone URL", shortcut: "cmd", icon: "doc.on.doc", action: {type: "copy", text: .clone_url}},
        {title: "Open Issues", icon: "exclamationmark.bubble", action: {type: "open", url: "\(.html_url)/issues"}}
      ]
    }]
  } else {
    items: [{title: (.message // "GitHub did not answer"), icon: "exclamationmark.triangle"}]
  } end'
