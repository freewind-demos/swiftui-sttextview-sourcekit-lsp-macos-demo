#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(pwd)}"
DEVELOPER_DIR="/System/Volumes/Data/Applications/Xcode.app/Contents/Developer"
SCRIPT_NAME="$(basename "${0}")"
TARGET_NAME="${TARGET_NAME:-${SCRIPT_NAME%.*}}"
SCHEME_NAME="${SCHEME_NAME:-${TARGET_NAME}}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${ROOT_DIR}/build"
BUILD_LOG_PATH="${BUILD_LOG_PATH:-${BUILD_DIR}/${TARGET_NAME}.xcodebuild.log}"
PROJECT_FILE="${PROJECT_FILE:-}"
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
  fallback_scheme="$(printf '%s\n' "${schemes_json}" | jq -r '.project.schemes[0] // empty')"
  scheme_count="$(printf '%s\n' "${schemes_json}" | jq -r '(.project.schemes // []) | length')"

  if [[ "${scheme_count}" == "1" && -n "${fallback_scheme}" ]]; then
    printf '%s\n' "${fallback_scheme}"
    return 0
  fi

  printf 'Missing scheme for target %s. Set TARGET_NAME or SCHEME_NAME.\n' "${TARGET_NAME}" >&2
  return 1
}

generate_project() {
  if [[ -f "${ROOT_DIR}/project.yml" ]]; then
    xcodegen generate --spec "${ROOT_DIR}/project.yml"
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

resolve_product_path() {
  local build_dir full_product_name
  build_dir="$(read_build_setting TARGET_BUILD_DIR)"
  full_product_name="$(read_build_setting FULL_PRODUCT_NAME)"
  [[ -n "${build_dir}" && -n "${full_product_name}" ]] || return 1

  printf '%s/%s\n' "${build_dir}" "${full_product_name}"
}

build_product() {
  printf '\n==> Building %s (%s)\n' "${SCHEME_NAME}" "${CONFIGURATION}"
  if ! xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    build | tee "${BUILD_LOG_PATH}"; then
    printf 'Build failed.\n' >&2
    return 1
  fi
}

reveal_product() {
  local product_path linked_path product_dir

  refresh_build_settings
  product_path="$(resolve_product_path)"
  if [[ ! -e "${product_path}" ]]; then
    printf 'Missing built product: %s\n' "${product_path}" >&2
    return 1
  fi

  linked_path="${BUILD_DIR}/$(basename "${product_path}")"
  product_dir="$(dirname "${product_path}")"
  ln -sfn "${product_path}" "${linked_path}"
  open "${product_dir}"

  printf 'Root: %s\n' "${ROOT_DIR}"
  printf 'Project: %s\n' "${PROJECT_FILE}"
  printf 'Scheme: %s\n' "${SCHEME_NAME}"
  printf 'Product: %s\n' "${product_path}"
  printf 'Shortcut: %s\n' "${linked_path}"
  printf 'Build log: %s\n' "${BUILD_LOG_PATH}"
}

mkdir -p "${BUILD_DIR}"

generate_project
build_product
reveal_product
