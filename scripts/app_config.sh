#!/usr/bin/env bash

DEFAULT_BUILD_PRODUCT_NAME="NexAskApp"
DEFAULT_EXECUTABLE_NAME="NexAsk"
DEFAULT_PRODUCT_NAME="NexAsk"
DEFAULT_BUNDLE_ID="com.nexask.mac"
DEFAULT_DIST_BASENAME="NexAsk"
DEFAULT_PRODUCT_PROFILE="nexask"
DEFAULT_NOTARY_PROFILE_HINT="NexAsk-Notary"
DEFAULT_SPARKLE_KEY_ACCOUNT="NexAsk"
DEFAULT_UPDATE_CHECK_INTERVAL="14400"
DEFAULT_SMOKE_NAMESPACE="nexask"

derive_release_base_url() {
  local update_feed_url="${1:-}"
  if [[ -z "$update_feed_url" ]]; then
    return 1
  fi

  case "$update_feed_url" in
    */updates/appcast.xml)
      printf '%s\n' "${update_feed_url%/updates/appcast.xml}/releases"
      return 0
      ;;
  esac

  return 1
}

derive_release_target_dir() {
  local update_target_dir="${1:-}"
  if [[ -z "$update_target_dir" ]]; then
    return 1
  fi

  case "$update_target_dir" in
    */updates)
      printf '%s\n' "${update_target_dir%/updates}/releases"
      return 0
      ;;
  esac

  return 1
}

load_app_config() {
  export NEXHUB_BUILD_PRODUCT_NAME="${NEXHUB_BUILD_PRODUCT_NAME:-$DEFAULT_BUILD_PRODUCT_NAME}"
  export NEXHUB_EXECUTABLE_NAME="${NEXHUB_EXECUTABLE_NAME:-$DEFAULT_EXECUTABLE_NAME}"
  export NEXHUB_PRODUCT_NAME="${NEXHUB_PRODUCT_NAME:-$DEFAULT_PRODUCT_NAME}"
  export NEXHUB_BUNDLE_ID="${NEXHUB_BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
  export NEXHUB_DIST_BASENAME="${NEXHUB_DIST_BASENAME:-$DEFAULT_DIST_BASENAME}"
  export NEXHUB_PRODUCT_PROFILE="${NEXHUB_PRODUCT_PROFILE:-$DEFAULT_PRODUCT_PROFILE}"
  export NEXHUB_SUPPORT_DIR_NAME="${NEXHUB_SUPPORT_DIR_NAME:-$NEXHUB_PRODUCT_NAME}"
  export NEXHUB_NOTARY_PROFILE_HINT="${NEXHUB_NOTARY_PROFILE_HINT:-$DEFAULT_NOTARY_PROFILE_HINT}"
  export NEXHUB_SPARKLE_KEY_ACCOUNT="${NEXHUB_SPARKLE_KEY_ACCOUNT:-$DEFAULT_SPARKLE_KEY_ACCOUNT}"
  export NEXHUB_UPDATE_CHECK_INTERVAL="${NEXHUB_UPDATE_CHECK_INTERVAL:-$DEFAULT_UPDATE_CHECK_INTERVAL}"
  export NEXHUB_SMOKE_NAMESPACE="${NEXHUB_SMOKE_NAMESPACE:-$DEFAULT_SMOKE_NAMESPACE}"

  if [[ -z "${NEXHUB_RELEASE_PUBLISH_HOST:-}" && -n "${NEXHUB_UPDATE_PUBLISH_HOST:-}" ]]; then
    export NEXHUB_RELEASE_PUBLISH_HOST="$NEXHUB_UPDATE_PUBLISH_HOST"
  fi
  if [[ -z "${NEXHUB_RELEASE_PUBLISH_USER:-}" && -n "${NEXHUB_UPDATE_PUBLISH_USER:-}" ]]; then
    export NEXHUB_RELEASE_PUBLISH_USER="$NEXHUB_UPDATE_PUBLISH_USER"
  fi
  if [[ -z "${NEXHUB_RELEASE_PUBLISH_SSH_KEY_FILE:-}" && -n "${NEXHUB_UPDATE_PUBLISH_SSH_KEY_FILE:-}" ]]; then
    export NEXHUB_RELEASE_PUBLISH_SSH_KEY_FILE="$NEXHUB_UPDATE_PUBLISH_SSH_KEY_FILE"
  fi
  if [[ -z "${NEXHUB_RELEASE_PUBLISH_SSH_PORT:-}" && -n "${NEXHUB_UPDATE_PUBLISH_SSH_PORT:-}" ]]; then
    export NEXHUB_RELEASE_PUBLISH_SSH_PORT="$NEXHUB_UPDATE_PUBLISH_SSH_PORT"
  fi
  if [[ -z "${NEXHUB_RELEASE_PUBLISH_STRICT_HOST_KEY_CHECKING:-}" && -n "${NEXHUB_UPDATE_PUBLISH_STRICT_HOST_KEY_CHECKING:-}" ]]; then
    export NEXHUB_RELEASE_PUBLISH_STRICT_HOST_KEY_CHECKING="$NEXHUB_UPDATE_PUBLISH_STRICT_HOST_KEY_CHECKING"
  fi

  if [[ -z "${NEXHUB_RELEASE_PUBLISH_TARGET_DIR:-}" ]]; then
    local derived_release_target_dir=""
    derived_release_target_dir="$(derive_release_target_dir "${NEXHUB_UPDATE_PUBLISH_TARGET_DIR:-}" || true)"
    if [[ -n "$derived_release_target_dir" ]]; then
      export NEXHUB_RELEASE_PUBLISH_TARGET_DIR="$derived_release_target_dir"
    fi
  fi

  if [[ -z "${NEXHUB_RELEASE_BASE_URL:-}" ]]; then
    local derived_release_base_url=""
    derived_release_base_url="$(derive_release_base_url "${NEXHUB_UPDATE_FEED_URL:-}" || true)"
    if [[ -n "$derived_release_base_url" ]]; then
      export NEXHUB_RELEASE_BASE_URL="$derived_release_base_url"
    fi
  fi
}

sanitize_release_token() {
  local value="${1:-unknown}"
  printf '%s\n' "${value//[^0-9A-Za-z._-]/-}"
}

resolve_versioned_package_prefix() {
  local dist_basename="$1"
  local app_path="$2"

  if [[ ! -d "$app_path" ]]; then
    return 1
  fi

  local version=""
  local build=""
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist" 2>/dev/null || true)"

  if [[ -z "$version" || -z "$build" ]]; then
    return 1
  fi

  local safe_version=""
  local safe_build=""
  safe_version="$(sanitize_release_token "$version")"
  safe_build="$(sanitize_release_token "$build")"
  printf '%s\n' "${dist_basename}-${safe_version}-${safe_build}"
}

resolve_package_prefix() {
  local dist_basename="$1"
  local app_path="$2"
  local explicit_prefix="${3:-}"
  local fallback_suffix="${4:-}"

  if [[ -n "$explicit_prefix" ]]; then
    printf '%s\n' "$explicit_prefix"
    return 0
  fi

  local versioned_prefix=""
  versioned_prefix="$(resolve_versioned_package_prefix "$dist_basename" "$app_path" || true)"
  if [[ -n "$versioned_prefix" ]]; then
    printf '%s\n' "$versioned_prefix"
    return 0
  fi

  printf '%s\n' "${dist_basename}-${fallback_suffix}"
}

trim_file_value() {
  local path="$1"
  tr -d '[:space:]' < "$path"
}

is_valid_sparkle_public_key() {
  local candidate
  candidate="$(printf '%s' "${1:-}" | tr -d '[:space:]')"

  if [[ -z "$candidate" ]]; then
    return 1
  fi

  case "$candidate" in
    ERROR:*|error:*|Noexisting*|noexisting*)
      return 1
      ;;
  esac

  [[ "$candidate" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1

  local length=${#candidate}
  (( length >= 40 && length <= 128 )) || return 1
}

resolve_sparkle_public_key() {
  local explicit_value="${1:-}"
  local key_file="${2:-}"
  local key_account="${3:-}"
  local generate_keys_tool="${4:-}"
  local candidate=""

  RESOLVED_SPARKLE_PUBLIC_KEY=""
  RESOLVED_SPARKLE_PUBLIC_KEY_SOURCE=""

  candidate="$(printf '%s' "$explicit_value" | tr -d '[:space:]')"
  if is_valid_sparkle_public_key "$candidate"; then
    RESOLVED_SPARKLE_PUBLIC_KEY="$candidate"
    RESOLVED_SPARKLE_PUBLIC_KEY_SOURCE="env:NEXHUB_SPARKLE_PUBLIC_KEY"
    return 0
  fi

  if [[ -n "$key_file" && -f "$key_file" ]]; then
    candidate="$(trim_file_value "$key_file")"
    if is_valid_sparkle_public_key "$candidate"; then
      RESOLVED_SPARKLE_PUBLIC_KEY="$candidate"
      RESOLVED_SPARKLE_PUBLIC_KEY_SOURCE="$key_file"
      return 0
    fi
  fi

  if [[ -n "$key_account" && -x "$generate_keys_tool" ]]; then
    candidate="$("$generate_keys_tool" --account "$key_account" -p 2>/dev/null | tr -d '[:space:]' || true)"
    if is_valid_sparkle_public_key "$candidate"; then
      RESOLVED_SPARKLE_PUBLIC_KEY="$candidate"
      RESOLVED_SPARKLE_PUBLIC_KEY_SOURCE="keychain:$key_account"
      return 0
    fi
  fi

  return 1
}
