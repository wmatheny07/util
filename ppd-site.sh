#!/bin/bash
# Toggle peakprecisiondata.com maintenance mode.
# Usage: ppd-site [up|down|status]

FLAG=/opt/ppd/website/.maintenance

case "$1" in
  down)
    touch "$FLAG"
    echo "peakprecisiondata.com is DOWN (maintenance mode)"
    ;;
  up)
    rm -f "$FLAG"
    echo "peakprecisiondata.com is UP"
    ;;
  status)
    if [ -f "$FLAG" ]; then
      echo "DOWN (maintenance mode active)"
    else
      echo "UP"
    fi
    ;;
  *)
    echo "Usage: ppd-site [up|down|status]"
    exit 1
    ;;
esac
