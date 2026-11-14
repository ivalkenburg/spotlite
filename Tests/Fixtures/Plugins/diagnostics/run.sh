#!/bin/sh
case "$1" in
    env)
        echo "debug note" >&2
        printf '{"copy":"%s|%s|%s|%s|%s|%s|%s","toast":"applied"}' "$SPOTLITE_COMMAND" "$SPOTLITE_ACTION" \
            "$SPOTLITE_APPEARANCE" "$SPOTLITE_VERSION" "$SPOTLITE_CONFIG_LIMIT" "${SPOTLITE_CONFIG_API_KEY-unset}" "$SPOTLITE_QUERY"
        ;;
    fail) echo "starting" >&2; echo "fatal: it broke" >&2; exit 3 ;;
    invalid) echo "not json" ;;
    slow) echo $$ > "${TMPDIR:-/tmp}/spotlite-diagnostics-slow.pid"; sleep 10; echo '{}' ;;
esac
