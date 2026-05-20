#!/usr/bin/env bash
# debug.sh — Demo debug tracing
# Sourced by demo.sh when invoked with --debug.
#
# Provides:
#   set -x trace silently written to a temp log file via BASH_XTRACEFD
#   PS4 with wall-clock time, source file, line number, and function name
#   ERR trap — logs every command failure with exit code and context
#   dbg_step "label" — named checkpoint; shows dim progress on terminal
#                      and a timestamped marker in the log
#   EXIT trap — dumps the complete log to the terminal and removes the file
#
# Requires bash 4.2+ for \D{} in PS4 and printf %(...)T.

_DBG_LOG=$(mktemp /tmp/demo-debug-XXXXXX.log)
_DBG_START=$(date +%s)

# ── Redirect set -x trace to fd 9 → log file ─────────────────────
# BASH_XTRACEFD keeps xtrace off stderr so the demo terminal stays clean.
exec 9>>"${_DBG_LOG}"
BASH_XTRACEFD=9

# \D{%H:%M:%S} expands to the current time without forking a subshell.
# ${BASH_SOURCE##*/}:${LINENO} shows the file and line for every command.
# ${FUNCNAME[0]:+ (${FUNCNAME[0]})} appends the function name when inside one.
PS4='+[\D{%H:%M:%S} ${BASH_SOURCE##*/}:${LINENO}${FUNCNAME[0]:+ (${FUNCNAME[0]})}] '

set -x

# Write log header (to fd 9 so it goes into the file)
{
  printf '═%.0s' {1..64}; printf '\n'
  printf ' Demo Debug Log\n'
  printf ' Started : %s\n' "$(date)"
  printf ' PID     : %d\n' "$$"
  printf ' Script  : %s\n' "${BASH_SOURCE[1]:-demo.sh}"
  printf '═%.0s' {1..64}; printf '\n\n'
} >&9

# ── ERR trap — log failures ───────────────────────────────────────
_dbg_err() {
  local rc=$? line=${BASH_LINENO[0]} src=${BASH_SOURCE[1]:-?} fn=${FUNCNAME[1]:-main}
  printf '\n❌  ERROR  exit=%d  %s:%d  %s()\n    cmd : %s\n\n' \
    "$rc" "${src##*/}" "$line" "$fn" "${BASH_COMMAND}" >&9
}
trap '_dbg_err' ERR

# ── Named checkpoint ──────────────────────────────────────────────
# Usage: dbg_step "Act 2 — triggering install pipeline"
#
# Prints a faint one-liner to the terminal so you can see where the
# demo is while it runs, and writes a timestamped marker into the log.
dbg_step() {
  local elapsed=$(( $(date +%s) - _DBG_START ))
  # Dim/faint ANSI so it doesn't compete with the demo output
  printf '\e[2m[dbg +%ds] %s\e[0m\n' "$elapsed" "$*" >&2
  # Separator in the log file
  printf '\n┄┄┄ [+%ds] %s ┄┄┄\n\n' "$elapsed" "$*" >&9
}

# ── EXIT handler — dump log to terminal then delete ───────────────
_dbg_exit() {
  set +x
  exec 9>&-   # flush and close the trace fd

  [[ -f "${_DBG_LOG}" ]] || return

  printf '\n'
  printf '═%.0s' {1..64}; printf '\n'
  printf ' DEMO DEBUG LOG\n'
  printf '═%.0s' {1..64}; printf '\n'
  cat "${_DBG_LOG}"
  printf '═%.0s' {1..64}; printf '\n'
  rm -f "${_DBG_LOG}"
}
trap '_dbg_exit' EXIT
