#!/usr/bin/env bash
set -euo pipefail

# Host-only coverage for the three pure Swift packages. The app targets are
# deliberately not part of this report: they require Xcode/framework/device
# machinery and would make a host package test measure the wrong thing.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${SENDMETER_COVERAGE_OUTPUT_DIR:-$repo_root/coverage/swift}
mkdir -p "$output_dir"

if command -v xcrun >/dev/null 2>&1; then
  llvm_cov=$(xcrun --find llvm-cov 2>/dev/null || true)
  llvm_profdata=$(xcrun --find llvm-profdata 2>/dev/null || true)
else
  llvm_cov=''
  llvm_profdata=''
fi
llvm_cov=${llvm_cov:-$(command -v llvm-cov || true)}
llvm_profdata=${llvm_profdata:-$(command -v llvm-profdata || true)}

if [[ -z "$llvm_cov" || -z "$llvm_profdata" ]]; then
  echo "swift coverage requires llvm-cov and llvm-profdata" >&2
  exit 2
fi

profile_root=$(mktemp -d "${TMPDIR:-/tmp}/sendmeter-swift-coverage.XXXXXX")
declare -a resolved_files=()
declare -a resolved_backups=()
declare -a resolved_missing=()

restore_resolved_files() {
  local index
  for index in "${!resolved_files[@]}"; do
    if [[ "${resolved_missing[$index]}" == true ]]; then
      [[ ! -e "${resolved_files[$index]}" ]] || rm -f "${resolved_files[$index]}"
    else
      cp "${resolved_backups[$index]}" "${resolved_files[$index]}"
    fi
  done
}

cleanup() {
  rm -rf "$profile_root"
}
trap 'restore_resolved_files; cleanup' EXIT

run_package() {
  local label=$1
  local package_rel=$2
  local test_product=$3
  local minimum_lines=$4
  local minimum_functions=$5
  local ignore_regex=$6
  local package="$repo_root/$package_rel"
  local package_profiles="$profile_root/$label"
  local test_log="$package_profiles/test.log"
  local bin_dir
  local codecov_dir
  local binary=''
  local raw
  local report="$output_dir/$label.txt"
  local lcov="$output_dir/$label.lcov"
  local profdata="$output_dir/$label.profdata"
  local summary
  local line_percent
  local function_percent
  local -a raw_files=()

  [[ -d "$package" ]] || { echo "missing Swift package: $package" >&2; exit 2; }
  mkdir -p "$package_profiles"
  rm -f "$report" "$lcov" "$profdata"

  local resolved_file="$package/Package.resolved"
  local resolved_backup="$package_profiles/Package.resolved"
  if [[ -f "$resolved_file" ]]; then
    cp "$resolved_file" "$resolved_backup"
    resolved_missing+=(false)
  else
    resolved_missing+=(true)
  fi
  resolved_files+=("$resolved_file")
  resolved_backups+=("$resolved_backup")

  bin_dir=$(swift build \
    --package-path "$package" \
    --show-bin-path)
  codecov_dir="$bin_dir/codecov"
  if [[ -d "$codecov_dir" ]]; then
    # SwiftPM ignores an externally set LLVM_PROFILE_FILE and writes raw
    # profiles here. Remove only generated profiles for this package so stale
    # local runs cannot inflate this run's result.
    find "$codecov_dir" -type f -name '*.profraw' -delete
  fi

  if ! swift test \
    --package-path "$package" \
    --enable-code-coverage >"$test_log" 2>&1; then
    tail -80 "$test_log" >&2
    exit 1
  fi
  tail -12 "$test_log"

  while IFS= read -r -d '' raw; do
    if [[ -x "$raw" && "$raw" != *'.dSYM/'* ]]; then
      binary=$raw
      break
    fi
  done < <(
    find "$bin_dir" -type f \
      \( -name "$test_product" -o -name "$test_product.xctest" \) \
      -print0
  )
  if [[ -z "$binary" ]]; then
    echo "could not find Swift test executable $test_product in $bin_dir" >&2
    exit 2
  fi

  while IFS= read -r -d '' raw; do
    raw_files+=("$raw")
  done < <(find "$codecov_dir" -type f -name '*.profraw' -print0)
  if ((${#raw_files[@]} == 0)); then
    echo "swift test produced no raw coverage profiles for $label" >&2
    exit 2
  fi

  "$llvm_profdata" merge -sparse "${raw_files[@]}" -o "$profdata"
  "$llvm_cov" report "$binary" \
    --instr-profile="$profdata" \
    --ignore-filename-regex="$ignore_regex" \
    --show-branch-summary \
    | tee "$report"
  "$llvm_cov" export "$binary" \
    --instr-profile="$profdata" \
    --ignore-filename-regex="$ignore_regex" \
    --format=lcov > "$lcov"

  summary=$(awk '$1 == "TOTAL" { print $10, $7; found = 1 } END { if (!found) exit 1 }' "$report")
  read -r line_percent function_percent <<< "$summary"
  line_percent=${line_percent%\%}
  function_percent=${function_percent%\%}
  bash "$repo_root/scripts/check-coverage-threshold.sh" \
    "$label" "$line_percent" "$function_percent" "$minimum_lines" "$minimum_functions"
}

run_package \
  "SendmeterCore" \
  "native/SendmeterNative" \
  "SendmeterNativePackageTests" \
  89 \
  83 \
  '(^|/)(Tests|\.build)/|resource_bundle_accessor\.swift|ios/App/SendLogWatchCore/|native-plugins/sendlog-health-core/|native/SendmeterNative/Sources/Platform/'

run_package \
  "SendLogWatchCore" \
  "ios/App/SendLogWatchCore" \
  "SendLogWatchCorePackageTests" \
  94 \
  91 \
  '(^|/)(Tests|\.build)/|resource_bundle_accessor\.swift|native-plugins/sendlog-health-core/'

run_package \
  "SendLogHealthCore" \
  "native-plugins/sendlog-health-core" \
  "SendLogHealthCorePackageTests" \
  96 \
  92 \
  '(^|/)(Tests|\.build)/|resource_bundle_accessor\.swift'

echo "Swift coverage reports written to $output_dir"
