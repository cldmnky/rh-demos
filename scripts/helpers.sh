#!/usr/bin/env bash
#
# scripts/helpers.sh
# Shared presentation helpers for Red Hat Demo scripts
#

# Feature detection
HAS_GUM=false && command -v gum &>/dev/null && HAS_GUM=true
HAS_BAT=false && command -v bat &>/dev/null && HAS_BAT=true
HAS_REDHATSAY=false && command -v redhatsay &>/dev/null && HAS_REDHATSAY=true

# Override wait to respect NO_WAIT (preventing hangs in headless runs)
function wait() {
  if [ "${NO_WAIT:-false}" = "true" ]; then
    return 0
  fi
  if [[ "${PROMPT_TIMEOUT:-0}" == "0" ]]; then
    read -rs
  else
    read -rst "${PROMPT_TIMEOUT:-0}"
  fi
}

function act() {
  clear
  if [ "$HAS_GUM" = true ]; then
    gum style --bold --foreground=226 --border=double --padding="1 2" --margin="1 1" "Act $1 — $2"
  else
    printf '\n\033[1;33mAct %s — %s\033[0m\n\n' "$1" "$2"
  fi
  if [ -n "${_DEMO_START:-}" ]; then
    local elapsed=$(( $(date +%s) - _DEMO_START ))
    comment "Elapsed: $((elapsed / 60))m $((elapsed % 60))s"
  fi
  wait
  clear
}

function say() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --bold --padding="1 2" --margin="1 0" --foreground="${2:-117}"
  else
    printf '\n\033[1;36m%s\033[0m\n\n' "$1"
  fi
}

function comment() {
  if [ "$HAS_GUM" = true ]; then
    echo "$1" | gum style --italic --foreground=245 --padding="0 2"
  else
    printf '\033[3;90m# %s\033[0m\n' "$1"
  fi
}

function show_manifest() {
  if [ "$HAS_GUM" = true ]; then
    cat "$1" | gum format -t code -l yaml
  elif [ "$HAS_BAT" = true ]; then
    bat --style=plain --color=always --language=yaml "$1"
  else
    cat "$1"
  fi
}

# Alias show_yaml to show_manifest for backward compatibility
function show_yaml() {
  show_manifest "$1"
}

function show_image() {
  local file="$1"
  if command -v viu &>/dev/null; then
    viu "$file"
  else
    if [ "$HAS_GUM" = true ]; then
      gum style --border="rounded" --border-foreground="33" --padding="0 2" "Image: $file"
    else
      printf '\n\033[1;34m[Image: %s]\033[0m\n\n' "$file"
    fi
  fi
}

function redhatsay() {
  local input
  if [ ! -t 0 ]; then
    input=$(cat)
  else
    input="$*"
  fi

  if [ "$HAS_REDHATSAY" = true ]; then
    if [ "$HAS_GUM" = true ]; then
      printf '%s\n' "$input" | gum format -t markdown 2>/dev/null | command redhatsay "$@" 2>/dev/null || printf '\n\033[1;31m%s\033[0m\n\n' "$input"
    else
      printf '%s\n' "$input" | command redhatsay "$@" 2>/dev/null || printf '\n\033[1;31m%s\033[0m\n\n' "$input"
    fi
  else
    if [ "$HAS_GUM" = true ]; then
      if [ -n "$input" ]; then
        gum style --border="double" --border-foreground="196" --padding="1 2" --margin="1 1" --align="center" "$input"
      fi
    else
      if [ -n "$input" ]; then
        printf '\n\033[1;31m%s\033[0m\n\n' "$input"
      fi
    fi
  fi
}
