# hack/lib/portable.sh - helpers that behave the same on Linux (GNU), macOS (BSD userland, bash 3.2) and Windows
# (Git Bash / MSYS2). Source it; it defines functions only and changes no shell options.
# Rules for every script in this repo (docs/dev-environment.md): bash 3.2 syntax (no mapfile, assoc arrays, ${v,,},
# &>>), expand possibly-empty arrays as ${a[@]+"${a[@]}"} under `set -u`, no GNU-only flags (sed -i, readlink -f,
# date -d, grep -P, xargs -r, df -B, base64 -d), no `timeout`, temp files via mktemp.
# shellcheck shell=bash

# os_name -> linux | darwin | windows (Git Bash, MSYS2, Cygwin). WSL reports linux (it is one).
os_name() {
  case "$(uname -s)" in
    Linux*) echo linux ;;
    Darwin*) echo darwin ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) uname -s | tr '[:upper:]' '[:lower:]' ;;
  esac
}

is_wsl() { [[ -r /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; }

# sed_inplace <sed-expr> <file>... : GNU `sed -i` and BSD `sed -i ''` disagree; write via a temp file instead.
# Returns 1 (file untouched) when sed fails, so callers under `set -e` stop on a bad expression.
sed_inplace() {
  local expr=$1 f tmp; shift
  for f in "$@"; do
    tmp=$(mktemp "${f}.XXXXXX")
    sed "$expr" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$f"   # cat keeps the original file's mode
    rm -f "$tmp"
  done
}

# file_group_other_perms <file> -> the group+other part of the mode as `ls -l` shows it (e.g. `------`, `r--r--`).
# `stat` flags differ between GNU and BSD; `ls -lLd` (POSIX, follows symlinks) is the same everywhere. Prints nothing
# on Windows, where Git Bash fakes the mode bits (NTFS ACLs decide), or when the file does not exist.
file_group_other_perms() {
  if [[ "$(os_name)" != windows && -e "$1" ]]; then
    # shellcheck disable=SC2012  # only the mode column of a single, quoted path is read
    ls -lLd -- "$1" 2>/dev/null | awk '{ print substr($1, 5, 6) }'
  fi
}

# b64dec: decode base64 from stdin. GNU and macOS >= 13 accept --decode; BusyBox and old macOS only -d / -D.
b64dec() {
  if printf 'YQ==' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  elif printf 'YQ==' | base64 -d >/dev/null 2>&1; then
    base64 -d
  else
    base64 -D
  fi
}

# sha1 <string> -> hex digest (sha1sum on GNU/Git Bash, shasum on macOS, openssl as last resort).
sha1() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else
    printf '%s' "$1" | openssl dgst -sha1 | sed 's/^.*= *//'
  fi
}

# sha256_file <file> -> hex digest (GNU sha256sum, macOS shasum; macOS 26's BSD sha256sum is avoided: other flags).
sha256_file() {
  if [[ "$(os_name)" != darwin ]] && command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    openssl dgst -sha256 -r "$1" | awk '{ print $1 }'
  fi
}

# free_gb <path> -> free space in GiB (POSIX `df -P`, 1K blocks; GNU `df -BG --output` does not exist on macOS).
free_gb() { df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 { print int($4 / 1048576) }'; }

# cpu_count -> logical CPU count (getconf on Linux/macOS, sysctl on BSD/macOS, fallback 4).
cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# native_path <path>: path as native programs see it. On Windows, Go/Python binaries (helm, kubeconform, python)
# do not understand MSYS paths like /c/Users/x; cygpath -m gives C:/Users/x, which bash accepts as well.
native_path() {
  if [[ "$(os_name)" == windows ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

# pick_python: set PYTHON to a working Python >= 3.8. Windows ships a `python3` App Execution Alias that only opens
# the Microsoft Store, and python-build-standalone (mise) installs `python`, so probe by running, not command -v.
pick_python() {
  local c
  export PYTHONUTF8=1   # Windows defaults to cp1252 for files and pipes; CRDs contain UTF-8
  [[ -n "${PYTHON:-}" ]] && return 0
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 \
      && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      PYTHON=$c
      return 0
    fi
  done
  return 1
}

# py <args>: run Python with LF-only stdout (Windows Python writes CRLF in text mode; $(...) keeps the `\r`).
py() {
  pick_python || { echo "python >= 3.8 not found (mise install)" >&2; return 127; }
  "$PYTHON" "$@" | tr -d '\r'
}

# open_url <url>: open in the default browser if this host has one; never fails.
open_url() {
  local url=$1
  [[ -n "${NO_BROWSER:-}" ]] && return 0
  case "$HOST_OS" in
    darwin) open "$url" >/dev/null 2>&1 ;;
    windows) cmd.exe //c start "" "$url" >/dev/null 2>&1 ;;
    linux)
      if is_wsl && command -v wslview >/dev/null 2>&1; then wslview "$url" >/dev/null 2>&1
      elif is_wsl; then cmd.exe /c start "" "$url" >/dev/null 2>&1
      elif command -v xdg-open >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then xdg-open "$url" >/dev/null 2>&1
      fi ;;
  esac
  return 0
}

# retry_with_backoff <attempts> <initial_delay_s> <command...>: retry transient failures with exponential backoff.
retry_with_backoff() {
  local attempts=$1 delay=$2 try=1 rc=0
  shift 2
  while true; do
    "$@" && return 0 || rc=$?
    if [[ $try -ge $attempts ]]; then
      echo "ERROR: failed after $attempts attempt(s) (exit $rc): $*" >&2
      return "$rc"
    fi
    echo "WARN: attempt $try/$attempts failed (exit $rc): $* (retrying in ${delay}s)" >&2
    sleep "$delay"
    try=$((try + 1))
    delay=$((delay * 2))
  done
}

# read_lines <array-name> <command...>: bash 3.2 replacement for `mapfile -t name < <(command)`.
read_lines() {
  local __name=$1 __line; shift
  eval "$__name=()"
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    eval "$__name+=(\"\$__line\")"
  done < <("$@")
}
