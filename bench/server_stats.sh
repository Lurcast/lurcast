#!/bin/sh
# Measures a running Lurcast server while a load test runs against it: the CPU it uses and its
# memory, over a window. Run it on the server's machine once every listener has connected.
#
#   bench/server_stats.sh PID [SECONDS] [LISTENERS]
#
# With LISTENERS, memory is also shown per listener. Linux reads /proc; elsewhere it uses ps.
set -eu

pid=${1:?usage: server_stats.sh PID [SECONDS] [LISTENERS]}
window=${2:-30}
listeners=${3:-0}

# Seconds of CPU (user and system) the process has used so far.
cpu_seconds() {
  if [ -r "/proc/$pid/stat" ]; then
    # Fields after the command name, which is in parentheses: utime and stime are 12th and 13th.
    sed 's/.*) //' "/proc/$pid/stat" | awk -v hz="$(getconf CLK_TCK)" '{ print ($12 + $13) / hz }'
  else
    ps -o time= -p "$pid" | awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else print $1 * 60 + $2 }'
  fi
}

rss_kib() {
  ps -o rss= -p "$pid" | tr -d ' '
}

start=$(cpu_seconds)
sleep "$window"
finish=$(cpu_seconds)
rss=$(rss_kib)

awk -v start="$start" -v finish="$finish" -v window="$window" -v rss="$rss" -v listeners="$listeners" 'BEGIN {
  printf "cpu: %.2f cores over %d s\n", (finish - start) / window, window
  printf "memory: %d MB resident", rss / 1024
  if (listeners > 0) printf ", %.1f KB per listener", rss / listeners
  printf "\n"
}'
