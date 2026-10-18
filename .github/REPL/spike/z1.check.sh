#!/usr/bin/env bash
# plan 01 Z :test_tool: -- the prg answer's library list for BIN == `objdump -p BIN | rg NEEDED`.
# usage: z1.check.sh ANSWER_JSON [BIN]   (exit 0 = match)
set -euo pipefail
A=$1; B=${2:-/usr/local/bin/bin2md}; n=$(basename "$B")
# a group row is [cell-ids..., rowid, <cols[1:]>]: align the named cols to the row's tail.
ans=$(jq -r --arg n "$n" '.groups[]|select(.file=="needed.csv")|(.cols[1:]) as $c|.rows[]
  |.[(length-($c|length)):] as $v|[$c,$v]|transpose|map({key:.[0],value:.[1]})|from_entries
  |select(.binary==$n)|.library' "$A" | { grep -v '^(none)$' || true; } | sort -u)
obj=$( (objdump -p "$B" | rg NEEDED || true) | awk '{print $2}' | sort -u)
echo "prg answer libraries for $n: [${ans//$'\n'/ }]"
echo "objdump -p NEEDED for $n:    [${obj//$'\n'/ }]"
[ "$ans" = "$obj" ] && echo MATCH || { echo MISMATCH; exit 1; }
