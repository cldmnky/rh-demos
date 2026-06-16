---
name: demo-magic
description: Create engaging, robust command-line presentations using demo-magic.sh and modern helper tools.
license: MIT
compatibility: opencode
metadata:
  purpose: interactive-terminal-demos
  framework: bash
---

## What I do
- Help author and refine interactive, self-typing terminal presentation scripts.
- Document and troubleshoot `demo-magic.sh` helper functions and customization variables.
- Provide production-grade patterns for gracefully handling CLI dependencies (`gum`, `bat`, `redhatsay`, `viu`, `asciinema`, media players), background tasks, browser integration, and slide-like terminal structuring.
- Improve demo pacing with title cards, visual interludes, pre-recorded output, and clear transitions while keeping scripts generic and repeatable.

## When to use me
Use this skill when editing or creating presentation scripts that automate CLI actions for live audiences, or when troubleshooting execution halts caused by interactive prompt waits.

---

## 1. Core API Reference (`demo-magic.sh`)

### Commands
- `p "text"`: Prints a command or comment simulating natural keyboard typing.
- `pe "command"`: Simulates typing, waits for the presenter to press `ENTER`, then runs the command.
- `pei "command"`: Simulates typing and executes the command immediately without waiting for `ENTER`.
- `wait`: Explicitly pauses script execution until the user presses a key.
- `cmd`: Pauses to allow the presenter to type and execute a single manual command in-line.
- `repl`: Enters interactive REPL mode. Type `exit` to resume the script.

### Variables
- `TYPE_SPEED`: Keyboard simulation speed (default: `20`; higher is faster; unset or disable with `-d`).
- `NO_WAIT`: If `true`, auto-advances through `pe`/`p` commands (default: `false`; enable with `-n`).
- `PROMPT_TIMEOUT`: Max seconds to wait before auto-advancing automatically (default: `0`).
- `DEMO_PROMPT`: Custom terminal prompt prefix (default: `"$ "`).
- `DEMO_CMD_COLOR` / `DEMO_COMMENT_COLOR`: Color overrides using standard ANSI sequences.

### Handy Colors
Use these variables inline for rich output:
- `BLACK`, `BLUE`, `GREEN`, `GREY`, `CYAN`, `RED`, `PURPLE`, `BROWN`, `WHITE`, `BOLD`, `COLOR_RESET`

---

## 2. "Great Demo" Engineering Recipes

### Pattern A: Feature Detection & Fallbacks
Do not assume standard presenter utilities exist. Gracefully degrade if they are missing:
```bash
HAS_GUM=false && command -v gum &>/dev/null && HAS_GUM=true
HAS_BAT=false && command -v bat &>/dev/null && HAS_BAT=true

explain() {
  if command -v redhatsay &>/dev/null; then
    redhatsay "$1"
  else
    echo -e "\033[1;33m$1\033[0m"
  fi
}

show_yaml() {
  local file=$1
  if [ "$HAS_BAT" = true ]; then
    bat --style=plain --color=always --language=yaml "$file"
  else
    less -R "$file"
  fi
}
```

### Pattern B: Dynamic Background Tasks (Port-Forwarding)
Run port-forwards or background tasks asynchronously, wait for connectivity, open the browser, and cleanly kill the process after a keypress:
```bash
# Start port-forward in background and capture PID
oc port-forward -n my-ns svc/my-service 8080:8080 &
PF_PID=$!
sleep 3  # wait for connection to settle

echo -e "Service UI: http://localhost:8080"
open "http://localhost:8080"

wait  # Wait for user input to continue

# Tear down port-forward
kill $PF_PID 2>/dev/null || true
```

### Pattern C: Agenda, Architecture & Slides
Structure the presentation chronologically:
1. **Title & Time Frame:** Outline the duration (e.g., "Duration: 10 mins") and high-level goals.
2. **Architecture Slide:** Use Unicode/ASCII heredocs (`cat << 'EOF'`) inside `less` or standard output before typing.
3. **Interactive Step-by-Step:** Distinct phases with clear header blocks.
4. **Key Takeaways:** Summarize what was accomplished and list reference URLs.

For a polished live presentation, treat terminal output as slides:
```bash
title() {
  clear
  if command -v redhatsay &>/dev/null; then
    redhatsay "$1"
  else
    printf '\n\033[1;36m%s\033[0m\n\n' "$1"
  fi
  wait
  clear
}

title "Act 1 — Build the base image"
```

Use `clear` intentionally between acts so the audience sees one idea at a time. Avoid clearing immediately after important output; pause first so people can read it.

### Pattern D: Speeding Up, Silencing, and Hiding Demo Steps
To maintain a high-impact, professional pacing, handle boring boilerplate and noisy operations gracefully:

1. **Use `pei` (Print & Execute Immediate) for Minor Steps:**
   Use `pei` instead of `pe` for expected setup commands (like applying RBAC, creating namespaces, or waiting for pods) to run them without requiring manual keystrokes to start:
   ```bash
   pei "oc apply -f manifests/rbac.yaml"
   pei "oc wait --for=condition=Ready pods -l app=test --timeout=60s"
   ```

2. **Adjust or Bypass Typing Speeds (`TYPE_SPEED`):**
   Unset or increase `TYPE_SPEED` to execute complex commands or repetitive blocks instantly:
   ```bash
   # Type a verbose command instantly, but still wait for ENTER to execute:
   local OLD_SPEED=$TYPE_SPEED
   unset TYPE_SPEED
   pe "oc patch deployment my-app -p '$(cat patch.json)'"
   TYPE_SPEED=$OLD_SPEED
   ```

3. **Silent Executions (Completely Hidden Setup/Cleanup):**
   Run pre-flight checks, cleanup routines, or state resets as standard bash commands directly (without `pe` or `pei` wrappers). This runs them silently in the background without cluttering the presenter prompt:
   ```bash
   # Executed silently without appearing on the demo screen:
   oc delete ns test-ns >/dev/null 2>&1 || true
   ```

4. **Suppress Command Output Noise:**
   When using `pe` or `pei` for commands that produce a wall of text (such as raw YAML updates or JSON patches), redirect stdout/stderr to clean up the screen:
   ```bash
   pei "oc patch application my-app --type=merge -p '{\"spec\":{\"syncPolicy\":{}}}' >/dev/null"
   ```

### Pattern E: Visual Interludes and Rich Terminal Media

Live demos are easier to follow when technical commands are separated by short visual or narrative beats. Keep these optional and feature-detected so the demo still runs on a plain terminal:

```bash
show_image() {
  local image=$1
  if command -v viu &>/dev/null; then
    viu "$image"
  else
    printf 'Image: %s\n' "$image"
  fi
}

show_code() {
  local file=$1 language=${2:-bash}
  if command -v gum &>/dev/null; then
    gum format -t code -l "$language" < "$file"
  elif command -v bat &>/dev/null; then
    bat --style=plain --color=always --language="$language" "$file"
  else
    sed -n '1,160p' "$file"
  fi
}

caption() {
  local text=$1 color=${2:-117}
  if command -v gum &>/dev/null; then
    printf '%s\n' "$text" | gum style --bold --padding="1 2" --margin="1 0" --foreground="$color"
  else
    printf '\n\033[1m%s\033[0m\n\n' "$text"
  fi
}
```

Good uses:
- Show an architecture diagram before touching the cluster.
- Display a short source file or manifest, then explain why it matters.
- Use a brief animation/video only for operations that are slow, noisy, or unreliable live.

### Pattern F: Pre-recorded Segments Without Losing the Story

For long builds, imports, or provisioning steps, play a deterministic recording and keep the live state checks around it:

```bash
p "oc get build my-build"
pei ""  # show the typed command, but use prepared output or a recording next

if command -v asciinema &>/dev/null && [ -f assets/build.cast ]; then
  asciinema play -m assets/build.cast -q
else
  pei "oc get build my-build"
fi

caption "The build produced both a container image and a bootable artifact." 82
wait
clear
```

Guidelines:
- Do not fake critical final state. After a recording, run a real verification command against the current environment.
- Keep recordings quiet (`-q`) and speed-adjusted (`-m`) so pacing matches the talk.
- Use `p` plus `pei ""` when you want to show a command prompt transition without executing the command directly.
- Keep media assets in a predictable `assets/` or `demo/assets/` directory and use paths relative to the repository root.

### Pattern G: Narrative Blocks Between Commands

Audience comprehension improves when each command has context before and after it:

```bash
caption "We start with a standard container build, then turn it into a bootable image." 226
wait
clear

show_code Containerfile dockerfile
caption "This file is still an OCI build recipe; the output can also boot as a VM." 117
wait
clear
```

Keep narration blocks short:
- State what the audience is about to see.
- Run or show the technical step.
- State the outcome in one sentence.
- Move on.

### Pattern H: Browser and External UI Handoffs

Opening a browser can be effective, but make it optional and reversible:

```bash
open_url() {
  local url=$1
  printf 'Open: %s\n' "$url"
  if command -v open &>/dev/null; then
    open "$url"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}
```

Prefer showing the URL before opening it. For demos that must run headlessly, guard browser calls behind an environment variable:

```bash
if [ "${OPEN_BROWSER:-true}" = "true" ]; then
  open_url "http://localhost:8080"
fi
```

### Pattern I: Script Shape and Portability

Use a predictable script skeleton so demo scripts can run from different directories:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null); then
  :
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi
cd "$REPO_ROOT"

. "$REPO_ROOT/scripts/demo-magic.sh"

TYPE_SPEED=${TYPE_SPEED:-40}
DEMO_PROMPT="${GREEN}❯ ${COLOR_RESET}"
```

Use this structure for larger demos:
1. Hidden pre-flight reset and dependency checks.
2. Title card and architecture visual.
3. Setup phase for prerequisites/secrets.
4. Main acts with command, verification, and narration.
5. Rollback or cleanup story.
6. Closing comparison or takeaway slide.

### Pattern J: Standard Shared Helpers Library (`scripts/helpers.sh`)

To avoid duplicating boilerplate code across demo scripts, use the shared helper library located at `scripts/helpers.sh`. This library detects available tools (e.g. `gum`, `bat`, `redhatsay`) and provides standardized presentation functions.

Additionally, **it overrides the standard `wait` function** from `demo-magic.sh` to check for `$NO_WAIT`. This is critical because it ensures that when scripts are run in headless/automated test environments (with `-n` or `NO_WAIT=true`), the explicit `wait` calls do not block.

#### How to use it

Import the helpers library immediately after importing `demo-magic.sh`:

```bash
. "$REPO_ROOT/scripts/demo-magic.sh"
. "$REPO_ROOT/scripts/helpers.sh"
```

#### Shared Functions Provided

- **`act "num" "title"`**: Displays a bold, dual-bordered yellow block via `gum style` (or standard yellow text as fallback) representing a distinct act or phase of the presentation. Clears the screen, waits, and clears again. If a script defines `_DEMO_START=$(date +%s)`, it automatically calculates and prints elapsed time.
- **`say "text"`**: Prints main narrative points in bold cyan.
- **`comment "text"`**: Prints italicized gray comments.
- **`show_manifest "file.yaml"`** (and **`show_yaml "file.yaml"`**): Displays syntax-highlighted YAML/code using `gum format` or `bat`, falling back to `cat`.
- **`show_image "image.png"`**: Renders an image in the terminal using `viu` if available, or displays a cleanly-styled placeholder box with `gum` (or styled text) when `viu` is not installed.
- **`redhatsay "text"`**: Standardized wrapper that handles both piped inputs and inline arguments, integrating with `gum format` and formatting text as a red double-bordered box if the physical `redhatsay` command is absent.

---

## 3. Safe Agent Execution Rules

**CRITICAL: Never run interactive `demo-magic` scripts inside an OpenCode session without headless overrides.** They use blocking `read` calls and will freeze the agent's environment.
- **For headless verification:** Always append `-n` (No Wait) or `-w 1` (Wait 1 sec max) when testing a `demo-magic` based script:
  ```bash
  ./path/to/demo.sh -n
  ```
- **For logical verification:** Prefer running non-interactive test mirrors (if available), which execute all commands without `demo-magic` wrapper prompts.

When creating or reviewing demo scripts, also check:
- Every background process has a captured PID and cleanup path.
- Every external asset path exists or has a fallback.
- Every destructive command is scoped to demo-owned resources.
- Every long-running live operation has a timeout and a status command for debugging.
- Every pre-recorded segment is followed by a real state verification.
