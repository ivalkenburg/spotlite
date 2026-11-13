#!/bin/sh
# Keeps the display awake with /usr/bin/caffeinate, which outlives this script.
#   (no arguments)   list the durations, with Turn Off first while a session runs
#   start <seconds>  start or replace a session; 0 lasts until turned off
#   stop             end the session
# The session is one line in the data folder: "<pid> <deadline>", deadline 0 for none.

state="$SPOTLITE_PLUGIN_DATA/session"
pid=""
deadline=0

# True while the recorded process is still our caffeinate.
active() {
  [ -f "$state" ] || return 1
  read -r pid deadline < "$state" || return 1
  [ -n "$pid" ] && [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "/usr/bin/caffeinate" ]
}

stop() {
  if active; then kill "$pid" 2>/dev/null; fi
  rm -f "$state"
}

# The command's look in root results while a session runs.
look() {
  if [ "$deadline" -gt 0 ]; then
    printf '{"command":"caffeinate","icon":"cup.and.saucer.fill","subtitle":"Active until %s","expires":%s}' \
      "$(date -r "$deadline" +%H:%M)" "$deadline"
  else
    printf '{"command":"caffeinate","icon":"cup.and.saucer.fill","subtitle":"Active until turned off"}'
  fi
}

duration() {
  printf '{"id":"%s","title":"%s","icon":"%s","action":{"type":"run","args":["start","%s"]}}' "$1" "$2" "$3" "$1"
}

case "$1" in
  start)
    seconds="${2:-0}"
    stop
    if [ "$seconds" -gt 0 ]; then
      nohup /usr/bin/caffeinate -d -t "$seconds" >/dev/null 2>&1 &
      deadline=$(( $(date +%s) + seconds ))
    else
      nohup /usr/bin/caffeinate -d >/dev/null 2>&1 &
      deadline=0
    fi
    echo "$! $deadline" > "$state"
    printf '{"toast":{"text":"Caffeinate enabled","symbol":"cup.and.saucer.fill"},"update":[%s]}\n' "$(look)"
    ;;
  stop)
    stop
    printf '{"toast":{"text":"Caffeinate disabled","symbol":"cup.and.saucer"},"update":[{"command":"caffeinate"}]}\n'
    ;;
  *)
    printf '{"items":['
    if active; then
      printf '{"id":"stop","title":"Turn Off","icon":"cup.and.saucer.fill","action":{"type":"run","args":["stop"]}},'
      update=$(look)
    else
      rm -f "$state"
      update='{"command":"caffeinate"}'
    fi
    duration 0 "Until turned off" "cup.and.saucer"; printf ','
    duration 900 "15 minutes" "clock"; printf ','
    duration 1800 "30 minutes" "clock"; printf ','
    duration 3600 "1 hour" "clock"; printf ','
    duration 7200 "2 hours" "clock"
    printf '],"update":[%s]}\n' "$update"
    ;;
esac
