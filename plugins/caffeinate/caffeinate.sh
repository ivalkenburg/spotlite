#!/bin/sh
# Keeps the display awake with /usr/bin/caffeinate, which outlives this script but not
# Spotlite: -w ends it when Spotlite quits, as Spotlite's old built-in Caffeinate did.
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

# The command's look in root results and, unless the menuBar setting is off, the menu
# bar while a session runs. The pid ends the look when caffeinate exits, however that
# happens. Spotlite that sets SPOTLITE_PID writes {expires} in the user's time format;
# older Spotlite gets the time.
look() {
  menu=',"menuBar":{"actions":[{"title":"Turn Off","icon":"cup.and.saucer","action":{"type":"run","args":["stop"]}},{"title":"Change Duration…","icon":"clock","action":{"type":"list"}}]}'
  [ "$SPOTLITE_CONFIG_MENUBAR" = false ] && menu=''
  if [ "$deadline" -gt 0 ]; then
    if [ -n "$SPOTLITE_PID" ]; then until='{expires}'; else until=$(date -r "$deadline" +%H:%M); fi
    printf '{"command":"caffeinate","icon":"cup.and.saucer.fill","subtitle":"Active until %s","expires":%s,"pid":%s%s}' \
      "$until" "$deadline" "$pid" "$menu"
  else
    printf '{"command":"caffeinate","icon":"cup.and.saucer.fill","subtitle":"Active until turned off","pid":%s%s}' \
      "$pid" "$menu"
  fi
}

# The list is "sort": false, so typing narrows it but keeps the durations in order.
duration() {
  printf '{"id":"%s","title":"%s","icon":"%s","keywords":[%s],"action":{"type":"run","args":["start","%s"]}}' \
    "$1" "$2" "$3" "$4" "$1"
}

case "$1" in
  start)
    seconds="${2:-0}"
    stop
    # Older Spotlite sets no SPOTLITE_PID. It started this script, so it is $PPID.
    owner="${SPOTLITE_PID:-$PPID}"
    if [ "$seconds" -gt 0 ]; then
      nohup /usr/bin/caffeinate -d -t "$seconds" -w "$owner" >/dev/null 2>&1 &
      deadline=$(( $(date +%s) + seconds ))
    else
      nohup /usr/bin/caffeinate -d -w "$owner" >/dev/null 2>&1 &
      deadline=0
    fi
    pid=$!
    echo "$pid $deadline" > "$state"
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
    duration 0 "Until turned off" "cup.and.saucer" '"forever","indefinitely"'; printf ','
    duration 900 "15 minutes" "clock" '"quarter"'; printf ','
    duration 1800 "30 minutes" "clock" '"half hour"'; printf ','
    duration 3600 "1 hour" "clock" '"60 minutes"'; printf ','
    duration 7200 "2 hours" "clock" '"120 minutes"'
    printf '],"update":[%s]}\n' "$update"
    ;;
esac
