#!/bin/sh
case "$1" in
    keep-open)
        if [ "$2" = old ]; then sleep 0.35; else sleep 0.03; fi
        printf '{"items":[{"id":"result","title":"%s"}]}' "$2"
        ;;
    detached-copy) sleep 0.05; printf '{"copy":"detached-action"}' ;;
    list) printf '{"copy":"list-response","items":[]}' ;;
    search)
        if [ "$2" = beta ]; then sleep 0.4; fi
        if [ "$2" = dismissed ]; then sleep 0.03; fi
        printf '{"items":[{"title":"%s","action":{"type":"copy","text":"%s"}}],"copy":"response-%s"}' "$2" "$2" "$2"
        ;;
esac
