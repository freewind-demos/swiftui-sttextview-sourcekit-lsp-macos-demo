#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(pwd)}"
DEVELOPER_DIR="/System/Volumes/Data/Applications/Xcode.app/Contents/Developer"
SCRIPT_NAME="$(basename "${0}")"
TARGET_NAME="${TARGET_NAME:-${SCRIPT_NAME%.*}}"
SCHEME_NAME="${SCHEME_NAME:-${TARGET_NAME}}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${ROOT_DIR}/build"
APP_LOG_PATH="${APP_LOG_PATH:-${BUILD_DIR}/${TARGET_NAME}.dev.log}"
BUILD_LOG_PATH="${BUILD_LOG_PATH:-${BUILD_DIR}/${TARGET_NAME}.xcodebuild.log}"
WATCH_INTERVAL="${WATCH_INTERVAL:-1}"
PROJECT_FILE="${PROJECT_FILE:-}"
RUN_ONCE="${RUN_ONCE:-0}"
BUILD_SETTINGS_CACHE=""

export DEVELOPER_DIR

normalize_path() {
  local path="$1"
  case "${path}" in
    /*) printf '%s\n' "${path}" ;;
    *) printf '%s/%s\n' "${ROOT_DIR}" "${path}" ;;
  esac
}

resolve_project_file() {
  if [[ -n "${PROJECT_FILE}" ]]; then
    local explicit_project
    explicit_project="$(normalize_path "${PROJECT_FILE}")"
    [[ -f "${explicit_project}" ]] || {
      printf 'Missing project file: %s\n' "${explicit_project}" >&2
      return 1
    }
    printf '%s\n' "${explicit_project}"
    return 0
  fi

  local target_project="${ROOT_DIR}/${TARGET_NAME}.xcodeproj"
  if [[ -f "${target_project}" ]]; then
    printf '%s\n' "${target_project}"
    return 0
  fi

  local projects=()
  shopt -s nullglob
  projects=("${ROOT_DIR}"/*.xcodeproj)
  shopt -u nullglob

  if (( ${#projects[@]} == 1 )); then
    printf '%s\n' "${projects[0]}"
    return 0
  fi

  printf 'Missing project file for target %s. Set PROJECT_FILE.\n' "${TARGET_NAME}" >&2
  return 1
}

scheme_exists() {
  local scheme="$1"
  [[ -n "${scheme}" ]] || return 1
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${scheme}" \
    -configuration "${CONFIGURATION}" \
    -showBuildSettings >/dev/null 2>&1
}

resolve_scheme_name() {
  if scheme_exists "${SCHEME_NAME}"; then
    printf '%s\n' "${SCHEME_NAME}"
    return 0
  fi

  local schemes_json scheme_count fallback_scheme
  schemes_json="$(xcodebuild -project "${PROJECT_FILE}" -list -json 2>/dev/null || true)"
  fallback_scheme="$(printf '%s\n' "${schemes_json}" | rtk jq -r '.project.schemes[0] // empty')"
  scheme_count="$(printf '%s\n' "${schemes_json}" | rtk jq -r '(.project.schemes // []) | length')"

  if [[ "${scheme_count}" == "1" && -n "${fallback_scheme}" ]]; then
    printf '%s\n' "${fallback_scheme}"
    return 0
  fi

  printf 'Missing scheme for target %s. Set TARGET_NAME or SCHEME_NAME.\n' "${TARGET_NAME}" >&2
  return 1
}

generate_project() {
  if [[ -f "${ROOT_DIR}/project.yml" ]]; then
    rtk xcodegen generate --spec "${ROOT_DIR}/project.yml"
  fi

  PROJECT_FILE="$(resolve_project_file)"
  SCHEME_NAME="$(resolve_scheme_name)"
}

fetch_build_settings() {
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    -showBuildSettings 2>/dev/null
}

refresh_build_settings() {
  BUILD_SETTINGS_CACHE="$(fetch_build_settings)"
}

read_build_setting() {
  local key="$1"
  local line
  while IFS= read -r line; do
    case "${line}" in
      *"${key} = "*)
        printf '%s\n' "${line#*= }"
        return 0
        ;;
    esac
  done <<<"${BUILD_SETTINGS_CACHE}"

  return 1
}

resolve_app_bundle() {
  local build_dir full_product_name
  build_dir="$(read_build_setting TARGET_BUILD_DIR)"
  full_product_name="$(read_build_setting FULL_PRODUCT_NAME)"
  [[ -n "${build_dir}" && -n "${full_product_name}" ]] || return 1

  printf '%s/%s\n' "${build_dir}" "${full_product_name}"
}

resolve_app_binary() {
  local build_dir executable_path
  build_dir="$(read_build_setting TARGET_BUILD_DIR)"
  executable_path="$(read_build_setting EXECUTABLE_PATH)"
  [[ -n "${build_dir}" && -n "${executable_path}" ]] || return 1

  printf '%s/%s\n' "${build_dir}" "${executable_path}"
}

resolve_process_name() {
  read_build_setting EXECUTABLE_NAME
}

build_app() {
  printf '\n==> Building %s (%s)\n' "${SCHEME_NAME}" "${CONFIGURATION}"
  if ! xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    build | tee "${BUILD_LOG_PATH}"; then
    printf 'Build failed. Keep current app.\n' >&2
    return 1
  fi
}

restart_app() {
  local app_bundle app_bin process_name

  refresh_build_settings
  app_bundle="$(resolve_app_bundle)"
  app_bin="$(resolve_app_binary)"
  process_name="$(resolve_process_name)"

  if [[ ! -x "${app_bin}" ]]; then
    printf 'Missing built app binary: %s\n' "${app_bin}" >&2
    return 1
  fi

  rtk ln -sfn "${app_bundle}" "${BUILD_DIR}/$(basename "${app_bundle}")"
  if [[ -n "${process_name}" ]]; then
    rtk pkill -x "${process_name}" || true
  fi

  nohup "${app_bin}" >"${APP_LOG_PATH}" 2>&1 </dev/null &
  disown || true

  printf 'Root: %s\n' "${ROOT_DIR}"
  printf 'Project: %s\n' "${PROJECT_FILE}"
  printf 'Scheme: %s\n' "${SCHEME_NAME}"
  printf 'Launched app: %s\n' "${app_bundle}"
  printf 'App log: %s\n' "${APP_LOG_PATH}"
  printf 'Build log: %s\n' "${BUILD_LOG_PATH}"
}

list_watch_files() {
  if rtk git -C "${ROOT_DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
    (
      cd "${ROOT_DIR}"
      rtk git ls-files -co --exclude-standard --deduplicate
    )
    return 0
  fi

  (
    cd "${ROOT_DIR}"
    rtk fd -HI -t f \
      --exclude .git \
      --exclude build \
      --exclude DerivedData \
      .
  )
}

watch_fingerprint() {
  list_watch_files |
    LC_ALL=C sort |
    while IFS= read -r rel_path; do
      [[ -f "${ROOT_DIR}/${rel_path}" ]] || continue
      stat -f '%m %N' "${ROOT_DIR}/${rel_path}"
    done |
    shasum -a 1 | awk '{print $1}'
}

rtk mkdir -p "${BUILD_DIR}"

generate_project
build_app
restart_app

if [[ "${RUN_ONCE}" == "1" ]]; then
  exit 0
fi

last_fingerprint="$(watch_fingerprint)"
printf 'Watching for changes under: %s\n' "${ROOT_DIR}"

while true; do
  sleep "${WATCH_INTERVAL}"
  next_fingerprint="$(watch_fingerprint)"
  if [[ "${next_fingerprint}" == "${last_fingerprint}" ]]; then
    continue
  fi

  printf '\n==> Change detected\n'
  sleep 0.2
  generate_project
  if build_app; then
    restart_app
    last_fingerprint="$(watch_fingerprint)"
  fi
done
