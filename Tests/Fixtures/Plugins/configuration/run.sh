#!/bin/sh
if [ "$1" = slow ]; then sleep 0.3; fi
printf '%s' "$SPOTLITE_CONFIG"
