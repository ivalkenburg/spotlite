#!/bin/sh
case "$1" in
    confirmed) printf '{"copy":"confirmed-run"}' ;;
    rows)
        printf '{"items":[{"id":"alpha","title":"alpha","action":{"type":"open","url":"https://example.com/alpha"},'
        printf '"actions":[{"title":"Copy Clone URL","shortcut":"cmd","action":{"type":"copy","text":"clone-alpha"}},'
        printf '{"title":"Delete","shortcut":"ctrl","action":{"type":"run","args":["delete","alpha"],"keepOpen":true,"confirm":"Delete alpha?"}}]},'
        printf '{"id":"beta","title":"beta","action":{"type":"copy","text":"beta"}}]}'
        ;;
    delete) printf '{"copy":"deleted-%s"}' "$2" ;;
    late) sleep 0.3; printf '{"copy":"late-copy","items":[{"title":"late row"}]}' ;;
    fail) echo "fixture failure" >&2; exit 3 ;;
esac
