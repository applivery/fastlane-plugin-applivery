#!/usr/bin/env bash
#
# Runs the end-to-end tests of the plugin across the version matrix, one Docker
# image per row. See e2e/README.md.
#
# Written for bash 3.2, the one macOS ships. Never add `set -x`: the Applivery
# token is in the environment.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
E2E_DIR="$REPO_DIR/e2e"
LOG_DIR="$E2E_DIR/logs"
MATRIX_FILE="$E2E_DIR/matrix.txt"
CONFIG_FILE="$E2E_DIR/config.env"
SCENARIOS_FILE="$E2E_DIR/container/scenarios.rb"

ONLY=""
SUITE_OVERRIDE=""
DO_BUILD=1
LIST_ONLY=0
SHELL_ROW=""
PLATFORM=""

usage() {
  cat <<'USAGE'
Usage: e2e/run.sh [options]

  --only <rows>       Comma separated row names from e2e/matrix.txt
  --suite <name>      core | full | all (overrides the suite of every row)
  --no-build          Reuse the existing images instead of building them
  --shell <row>       Open a shell in that row's image, with the same mounts
  --platform <p>      Force a docker platform, e.g. linux/amd64
  --list              Print the matrix and the scenarios, run nothing
  -h, --help          This message

Every successful scenario uploads a real build to the app behind the token in
e2e/config.env. Notifications are disabled in all of them.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --suite) SUITE_OVERRIDE="${2:-}"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --shell) SHELL_ROW="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

### Configuration #####################################################

if [ ! -f "$MATRIX_FILE" ]; then
  echo "missing $MATRIX_FILE" >&2
  exit 1
fi

if [ "$LIST_ONLY" -eq 0 ]; then
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "missing $CONFIG_FILE" >&2
    echo "create it with: cp e2e/config.env.example e2e/config.env" >&2
    exit 1
  fi

  # The credentials must never end up in a commit
  if git -C "$REPO_DIR" ls-files --error-unmatch e2e/config.env >/dev/null 2>&1; then
    echo "e2e/config.env is tracked by git, remove it from the index before running" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a

  : "${E2E_APP_TOKEN:?set E2E_APP_TOKEN in e2e/config.env}"
  : "${E2E_BUILD_PATH:?set E2E_BUILD_PATH in e2e/config.env}"

  if [ ! -f "$E2E_BUILD_PATH" ]; then
    echo "the build to upload does not exist: $E2E_BUILD_PATH" >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "docker is not running" >&2
    exit 1
  fi

  # Passed to the containers by name, so the values stay out of the process list
  export APPLIVERY_APP_TOKEN="$E2E_APP_TOKEN"
  export APPLIVERY_TENANT="${E2E_TENANT:-}"
  export E2E_BAD_TOKEN="${E2E_BAD_TOKEN:-e2e-invalid-token}"
  export E2E_FILTER_GROUPS="${E2E_FILTER_GROUPS:-}"
  export E2E_SCENARIO_TIMEOUT="${E2E_SCENARIO_TIMEOUT:-600}"
  E2E_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  export E2E_RUN_ID
fi

### Matrix ############################################################

selected_rows=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac

  row_name="${line%%|*}"
  if [ -n "$ONLY" ]; then
    case ",$ONLY," in
      *",$row_name,"*) ;;
      *) continue ;;
    esac
  fi
  selected_rows="$selected_rows$line
"
done < "$MATRIX_FILE"

if [ -z "$selected_rows" ]; then
  echo "no rows selected${ONLY:+ for --only $ONLY}" >&2
  exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "Matrix (e2e/matrix.txt):"
  printf '  %-16s %-5s %-14s %-12s %s\n' NAME RUBY FASTLANE FARADAY SUITE
  while IFS='|' read -r name ruby fastlane_req faraday_req bundler_req expect_faraday suite allow_fail; do
    [ -z "$name" ] && continue
    note=""
    if [ "$allow_fail" = "1" ]; then
      note=" [allowed to fail]"
    fi
    printf '  %-16s %-5s %-14s %-12s %s%s\n' \
      "$name" "$ruby" "$fastlane_req" "${faraday_req:-(resolved)}" "$suite" "$note"
  done <<< "$selected_rows"
  echo
  echo "Scenarios (e2e/container/scenarios.rb):"
  awk -F"'" "/'name' =>/ { n = \$4 } /'suite' =>/ { printf \"  %-18s %s\n\", n, \$4 }" "$SCENARIOS_FILE"
  exit 0
fi

### Docker ############################################################

docker_run_args() {
  RUN_ARGS=(
    --rm
    -v "$E2E_BUILD_PATH:/build.apk:ro"
    -v "$E2E_BUILD_PATH:/builds/with space.apk:ro"
    -e APPLIVERY_APP_TOKEN
    -e APPLIVERY_TENANT
    -e E2E_BAD_TOKEN
    -e E2E_FILTER_GROUPS
    -e E2E_SCENARIO_TIMEOUT
    -e E2E_RUN_ID
    -e "E2E_ROW=$1"
    -e "E2E_SUITE=$2"
    -e "E2E_EXPECT_FARADAY=$3"
    -e "E2E_BUILD_PATH=/build.apk"
  )
  if [ -n "$PLATFORM" ]; then
    RUN_ARGS+=(--platform "$PLATFORM")
  fi
}

build_row() {
  BUILD_ARGS=(
    -f "$E2E_DIR/Dockerfile"
    -t "applivery-e2e:$1"
    --build-arg "RUBY_VERSION=$2"
    --build-arg "FASTLANE_REQ=$3"
    --build-arg "FARADAY_REQ=$4"
    --build-arg "BUNDLER_REQ=$5"
  )
  if [ -n "$PLATFORM" ]; then
    BUILD_ARGS+=(--platform "$PLATFORM")
  fi
  docker build "${BUILD_ARGS[@]}" "$REPO_DIR"
}

if [ -n "$SHELL_ROW" ]; then
  row_line="$(grep "^$SHELL_ROW|" <<< "$selected_rows" || true)"
  if [ -z "$row_line" ]; then
    echo "unknown row: $SHELL_ROW" >&2
    exit 1
  fi
  IFS='|' read -r name ruby fastlane_req faraday_req bundler_req expect_faraday suite allow_fail <<< "$row_line"
  if [ "$DO_BUILD" -eq 1 ]; then
    build_row "$name" "$ruby" "$fastlane_req" "$faraday_req" "$bundler_req"
  fi
  docker_run_args "$name" "${SUITE_OVERRIDE:-$suite}" "$expect_faraday"
  echo "Shell in $name. Scenarios in /e2e, workspaces in /work (created by the runner)."
  echo "Try: ruby /e2e/scenarios.rb"
  echo "  or: cd /work/tagged && bundle exec fastlane android minimal --verbose"
  exec docker run -it "${RUN_ARGS[@]}" "applivery-e2e:$name" bash
fi

### Run ###############################################################

mkdir -p "$LOG_DIR"
summary=""
overall=0

echo "run id: $E2E_RUN_ID"
echo "build:  $E2E_BUILD_PATH"
echo "tenant: ${APPLIVERY_TENANT:-applivery.io}"

while IFS='|' read -r name ruby fastlane_req faraday_req bundler_req expect_faraday suite allow_fail; do
  [ -z "$name" ] && continue
  if [ -n "$SUITE_OVERRIDE" ]; then
    suite="$SUITE_OVERRIDE"
  fi
  log_file="$LOG_DIR/$name.log"

  echo
  echo "######################################################################"
  echo "# $name: ruby $ruby, fastlane '$fastlane_req', faraday '${faraday_req:-resolved}', suite $suite"
  echo "######################################################################"

  if [ "$DO_BUILD" -eq 1 ]; then
    echo "building the image (log: $log_file.build)"
    if ! build_row "$name" "$ruby" "$fastlane_req" "$faraday_req" "$bundler_req" \
         > "$log_file.build" 2>&1; then
      echo "BUILD FAILED, last lines:"
      tail -25 "$log_file.build"
      if [ "$allow_fail" = "1" ]; then
        summary="$summary$name BUILD-WARN
"
      else
        summary="$summary$name BUILD-FAIL
"
        overall=1
      fi
      continue
    fi
  fi

  docker_run_args "$name" "$suite" "$expect_faraday"
  if docker run "${RUN_ARGS[@]}" "applivery-e2e:$name" 2>&1 | tee "$log_file"; then
    summary="$summary$name PASS
"
  elif [ "$allow_fail" = "1" ]; then
    summary="$summary$name WARN
"
  else
    summary="$summary$name FAIL
"
    overall=1
  fi
done <<< "$selected_rows"

echo
echo "######################################################################"
echo "# Summary (run $E2E_RUN_ID)"
echo "######################################################################"
while read -r row state; do
  [ -z "$row" ] && continue
  printf '  %-16s %s\n' "$row" "$state"
done <<< "$summary"
echo
echo "Per row logs: $LOG_DIR"

exit "$overall"
