#!/bin/sh
# Rows with pauses between them, so the panel shows some before the program exits.
case "$1" in
    list)
        printf '{"title":"alpha one"}\n{"title":"beta two"}\n'
        sleep 0.6
        printf '{"title":"alpha three"}\nnot json\n{"title":"gamma four"}\n'
        sleep 0.6
        printf '{"title":"alpha five"}\n{"toast":"stream finished"}'
        ;;
    late) sleep 0.6; echo '{"title":"late row"}' ;;
    empty) sleep 0.6 ;;
    fail) echo '{"title":"kept row"}'; sleep 0.2; echo "stream broke" >&2; exit 4 ;;
    many)
        i=0
        while [ $i -lt 500 ]; do
            printf '{"title":"Repository %d tools","subtitle":"Swift","accessory":"★ %d","keywords":["project%d"]}\n' $i $i $i
            i=$((i+1))
        done
        ;;
    search)
        echo $$ > "${TMPDIR:-/tmp}/spotlite-stream-search.pid"
        i=0
        while [ $i -lt 4 ]; do echo "{\"title\":\"$2 $i\"}"; i=$((i+1)); sleep 0.25; done
        ;;
esac
