#!/usr/bin/env bash
set -euo pipefail

if (($# != 5)); then
  echo "usage: $0 <label> <line-percent> <function-percent> <line-floor> <function-floor>" >&2
  exit 2
fi

label=$1
actual_lines=${2%%%}
actual_functions=${3%%%}
minimum_lines=${4%%%}
minimum_functions=${5%%%}
numeric='^[0-9]+([.][0-9]+)?$'

for value in "$actual_lines" "$actual_functions" "$minimum_lines" "$minimum_functions"; do
  if [[ ! "$value" =~ $numeric ]]; then
    echo "coverage threshold: non-numeric percentage: $value" >&2
    exit 2
  fi
done

failed=0
if ! awk -v actual="$actual_lines" -v minimum="$minimum_lines" \
  'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
  echo "coverage threshold failed: $label lines ${actual_lines}% < ${minimum_lines}%" >&2
  failed=1
fi

if ! awk -v actual="$actual_functions" -v minimum="$minimum_functions" \
  'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
  echo "coverage threshold failed: $label functions ${actual_functions}% < ${minimum_functions}%" >&2
  failed=1
fi

if ((failed)); then
  exit 1
fi

printf 'coverage threshold passed: %s lines %s%% (floor %s%%), functions %s%% (floor %s%%)\n' \
  "$label" "$actual_lines" "$minimum_lines" "$actual_functions" "$minimum_functions"
