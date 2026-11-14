#!/bin/sh
# Lists kubectl contexts, or switches to one.
#   (no arguments)  list contexts, the current one first, then alphabetical
#   use <context>   switch to it
# A failure's last nonempty line on standard error is what Spotlite shows.

command -v kubectl >/dev/null || { echo "kubectl was not found" >&2; exit 1; }

case "$1" in
  use)
    kubectl config use-context "$2" >/dev/null || exit 1
    jq -n --arg context "$2" '{toast: {text: ("Switched to " + $context), symbol: "checkmark.circle"}}'
    ;;
  *)
    current=$(kubectl config current-context 2>/dev/null)
    contexts=$(kubectl config get-contexts -o name) || exit 1
    printf '%s\n' "$contexts" | jq -Rn --arg current "$current" '{
      items: [[inputs | select(length > 0)] | sort_by(. != $current, ascii_downcase)[] | {
        id: .,
        title: .,
        subtitle: (if . == $current then "Current" else null end),
        icon: (if . == $current then "checkmark.circle.fill" else "circle" end),
        action: {type: "run", args: ["use", .]}
      }]
    }'
    ;;
esac
