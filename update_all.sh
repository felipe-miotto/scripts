#!/usr/bin/env zsh

# Colors
BOLD=$'\e[1m'
RESET=$'\e[0m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
BLUE=$'\e[34m'
CYAN=$'\e[36m'

# Strip color codes when stdout is not a terminal (e.g. piped to a log file)
if [[ ! -t 1 ]]; then
  BOLD='' RESET='' GREEN='' YELLOW='' BLUE='' CYAN=''
fi

# Flags
SKIP_BREW=false
GREEDY=false

for arg in "$@"; do
  case $arg in
    --skip-brew) SKIP_BREW=true ;;
    --greedy)    GREEDY=true ;;
    -h|--help)
      cat <<'EOF'
Usage: update_all.sh [options]

Updates Homebrew, Mac App Store, macOS, npm globals, conda, and AI dev tools.

Options:
  --skip-brew   Skip Homebrew formula/cask and Mac App Store updates
  --greedy      Upgrade casks including self-updating apps (--cask --greedy)
  -h, --help    Show this help and exit
EOF
      exit 0 ;;
  esac
done

# Track update steps that fail so the final summary reflects reality
# (zsh does not stop on a failed simple command, and these steps stream
#  their own output, so we record failures instead of relying on set -e).
FAILURES=()
fail() { FAILURES+=("$1"); echo "${YELLOW}${BOLD} ✗${RESET} ${1} failed" }
run() {
  local label=$1; shift
  "$@" || fail "$label"
  return 0
}
# Like run(), but retries the command with backoff before giving up. Use for
# network-dependent steps so a transient CDN/connection blip self-heals instead
# of failing the whole run. Records a failure only if every attempt fails.
run_retry() {
  local label=$1 tries=$2; shift 2
  # If we already know the network is down, don't grind through backoff waits —
  # attempt once so a false "offline" reading can't skip a step that would work.
  [[ ${OFFLINE:-false} == true ]] && tries=1
  local n=1
  while true; do
    "$@" && return 0
    if (( n >= tries )); then
      fail "$label (after $tries attempts)"
      return 0
    fi
    local wait=$(( n * 8 ))
    echo "${YELLOW}${BOLD} ⚠${RESET} ${label} failed (attempt ${n}/${tries}) — retrying in ${wait}s..."
    sleep $wait
    (( n++ ))
  done
}
# Lightweight reachability probe with short timeouts. Tries several reliable hosts
# so one blocked/down endpoint doesn't yield a false "offline". Used only to skip
# the retry-backoff grind when clearly offline — never to skip steps outright.
check_connectivity() {
  local host
  for host in https://formulae.brew.sh https://github.com https://registry.npmjs.org; do
    curl -fsS --max-time 4 -I "$host" >/dev/null 2>&1 && return 0
  done
  return 1
}

# Helpers
section() {
  local title="─── $1 "
  local pad_len=$(( 72 - ${#title} ))
  (( pad_len < 0 )) && pad_len=0
  local pad=$(printf '%0.s─' $(seq 1 $pad_len))
  echo ""
  echo "${BOLD}${CYAN}${title}${pad}${RESET}"
}
step() { echo "${BLUE} →${RESET} $1" }
ok()   { echo "${GREEN} ✓${RESET} $1" }

# Header
echo ""
echo "${BOLD}${CYAN}┌──────────────────────────────────────────────┐${RESET}"
echo "${BOLD}${CYAN}│        S Y S T E M   U P D A T E R          │${RESET}"
echo "${BOLD}${CYAN}└──────────────────────────────────────────────┘${RESET}"
echo ""

# Probe connectivity once up front. Every step here needs the network, so if we're
# offline we attempt each step once (clear, fast failures) instead of retrying.
OFFLINE=false
if ! check_connectivity; then
  OFFLINE=true
  echo "${YELLOW}${BOLD} ⚠  No network connectivity detected${RESET} — steps will be attempted once and may fail. Re-run when back online."
  echo ""
fi

# ─── Homebrew & Mac App Store ─────────────────────────────────────────
# As of Homebrew ~4.6+/6.x, `brew upgrade` prompts "Do you want to proceed? [y/n]"
# by default ("ask mode"). This script is meant to run unattended, so disable it.
# (Equivalent to passing --yes/-y to every upgrade call.)
export HOMEBREW_NO_ASK=1
# Harden Homebrew's own downloads (incl. the formulae.brew.sh metadata index that
# `brew update` fetches) against transient CDN/network failures. Default is 3.
export HOMEBREW_CURL_RETRIES=5
if [[ $SKIP_BREW == false ]]; then
  if command -v brew &>/dev/null; then

    section "Updating Applications"
    step "Fetching latest Homebrew formulas & taps..."
    run_retry "Homebrew update" 3 brew update

    step "Upgrading Homebrew formulas..."
    run_retry "Homebrew formula upgrade" 3 brew upgrade

    if [[ $GREEDY == true ]]; then
      step "Upgrading casks (including self-updating apps)..."
      run_retry "Cask upgrade (greedy)" 3 brew upgrade --cask --greedy
    else
      step "Upgrading Homebrew casks..."
      run_retry "Cask upgrade" 3 brew upgrade --cask
    fi

    if command -v mas &>/dev/null; then
      step "Updating Mac App Store apps..."
      # macOS Tahoe (26) no longer indexes kMDItemAppStoreHasReceipt in Spotlight,
      # so mas thinks every App Store app is "unindexed" and re-warns on every run.
      # Disable mas's auto-index/warn behaviour (cosmetic only — upgrades still work).
      run_retry "Mac App Store upgrade" 3 env MAS_NO_AUTO_INDEX=1 mas upgrade
    fi

    section "Cleaning Up"
    step "Removing orphaned dependencies..."
    run "Homebrew autoremove" brew autoremove

    step "Clearing Homebrew cache..."
    run "Homebrew cleanup" brew cleanup -s

    step "Running Homebrew doctor..."
    doctor_out=$(brew doctor 2>&1)
    if [[ $? -eq 0 ]]; then
      ok "System healthy"
    else
      echo "$doctor_out" | grep -vE "^Please note|^with debugging|^working fine|^just ignore|^Thanks" | while IFS= read -r line; do
        if [[ "$line" == Warning:* ]]; then
          echo "${YELLOW}${BOLD}$line${RESET}"
        else
          echo "$line"
        fi
      done
    fi

    echo ""
    ok "Homebrew & App Store — done!"

  else
    section "Updating Applications"
    echo "${YELLOW}${BOLD} ⚠${RESET} brew not found in PATH — skipping Homebrew & Mac App Store"
  fi
fi

# ─── macOS Software Updates ───────────────────────────────────────────
section "macOS Software Updates"
step "Checking for available updates..."
update_out=$(softwareupdate -l 2>&1)
if echo "$update_out" | grep -q "No new software available"; then
  ok "macOS is up to date"
else
  echo "$update_out" | grep "Title:" | while IFS= read -r line; do
    name=$(echo "$line" | sed 's/.*Title: \([^,]*\).*/\1/')
    size_kb=$(echo "$line" | sed 's/.*Size: \([0-9]*\)KiB.*/\1/')
    needs_restart=$(echo "$line" | grep -c "Action: restart")

    if [[ -n "$size_kb" ]] && (( size_kb > 1048576 )); then
      size=$(awk "BEGIN {printf \"%.1f GB\", $size_kb/1048576}")
    elif [[ -n "$size_kb" ]]; then
      size="$(( size_kb / 1024 )) MB"
    else
      size="unknown size"
    fi

    if [[ "$name" == *"Command Line Tools"* ]] || [[ "$name" == *"Xcode"* ]]; then
      notes_url="https://developer.apple.com/documentation/xcode-release-notes"
    else
      notes_url="https://support.apple.com/en-us/100100"
    fi

    if (( needs_restart > 0 )); then
      echo "  ${YELLOW}${BOLD}• $name${RESET}  ($size)  ${YELLOW}— requires restart${RESET}"
    else
      echo "  ${BOLD}• $name${RESET}  ($size)"
    fi
    echo "    ${BLUE}↳ Release notes:${RESET} $notes_url"
  done
  echo ""
  echo "${YELLOW}${BOLD}  → To install:${RESET} System Settings → General → Software Update"
fi
echo ""
ok "macOS — done!"

# ─── npm Global Packages ──────────────────────────────────────────────
if command -v npm &>/dev/null; then
  section "Updating npm Global Packages"
  step "Updating npm itself..."
  run_retry "npm self-update" 3 npm install -g npm --silent
  step "Updating global packages..."
  run_retry "npm global package update" 3 npm update -g --silent
  # `npm update -g` never crosses major versions — surface anything held back
  npm_outdated=$(npm outdated -g 2>/dev/null | tail -n +2)
  if [[ -n "$npm_outdated" ]]; then
    echo "${YELLOW}${BOLD} ⚠${RESET} Held back (major bump — update with: npm install -g <pkg>@latest):"
    echo "$npm_outdated" | awk '{printf "   %s  %s → %s\n", $1, $2, $4}'
  fi
  echo ""
  ok "npm — done!"
fi

# ─── Conda ────────────────────────────────────────────────────────────
if command -v conda &>/dev/null; then
  section "Updating Conda"
  step "Updating conda (base environment)..."
  conda_before=$(conda --version 2>/dev/null | awk '{print $2}')
  conda_fails_before=${#FAILURES[@]}
  # --all updates the entire base env in one transaction. Updating only the
  # `conda` package can silently freeze ("already installed") when companion
  # packages (e.g. the ToS plugin) must move with it.
  run_retry "conda update" 3 conda update -y -n base --all
  conda_after=$(conda --version 2>/dev/null | awk '{print $2}')
  # Only report status if the update step actually succeeded
  if (( ${#FAILURES[@]} == conda_fails_before )) && [[ -n "$conda_before" && -n "$conda_after" ]]; then
    if [[ "$conda_before" == "$conda_after" ]]; then
      echo "  conda is up to date ($conda_after)"
    else
      echo "  conda updated: $conda_before → $conda_after"
    fi
  fi
  echo ""
  ok "conda — done!"
fi

# ─── AI Developer Tools ───────────────────────────────────────────────
# "What's new" helpers — best-effort release notes shown only when a tool's
# version actually changed during this run. Any fetch/parse failure is silent.
claude_whats_new() {
  local from=$1 to=$2 notes
  notes=$(curl -fsS --max-time 8 \
    "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md" 2>/dev/null \
    | awk -v to="## ${to}" -v from="## ${from}" '
        index($0, to) == 1 {p=1}
        index($0, from) == 1 {exit}
        p {print}
      ' | head -40)
  if [[ -n "$notes" ]]; then
    echo "${CYAN}  What's new:${RESET}"
    echo "$notes" | sed 's/^/    /'
  fi
}
codex_whats_new() {
  local ver=$1 tag body
  for tag in "rust-v${ver}" "v${ver}"; do
    body=$(curl -fsS --max-time 8 \
      "https://api.github.com/repos/openai/codex/releases/tags/${tag}" 2>/dev/null \
      | jq -r '.body // empty' 2>/dev/null | head -40)
    [[ -n "$body" ]] && break
  done
  if [[ -n "$body" ]]; then
    echo "${CYAN}  What's new:${RESET}"
    echo "$body" | sed 's/^/    /'
  fi
}

section "Updating AI Developer Tools"

if command -v claude &>/dev/null; then
  step "Updating Claude Code..."
  claude_before=$(claude --version 2>/dev/null | awk '{print $1}')
  claude update 2>&1 | grep -vE "^$" | while IFS= read -r line; do
    echo "  $line"
  done
  (( ${pipestatus[1]} != 0 )) && fail "Claude Code update"
  claude_after=$(claude --version 2>/dev/null | awk '{print $1}')
  if [[ -n "$claude_before" && -n "$claude_after" && "$claude_before" != "$claude_after" ]]; then
    claude_whats_new "$claude_before" "$claude_after"
  fi
fi

if command -v npm &>/dev/null && npm list -g --depth=0 2>/dev/null | grep -q "@openai/codex"; then
  step "Updating Codex CLI..."
  codex_before=$(codex --version 2>/dev/null | awk '{print $2}')
  run_retry "Codex CLI update" 3 npm install -g @openai/codex@latest --silent
  codex_after=$(codex --version 2>/dev/null | awk '{print $2}')
  if [[ "$codex_before" == "$codex_after" ]]; then
    echo "  Codex CLI is up to date ($codex_after)"
  else
    echo "  Codex CLI updated: $codex_before → $codex_after"
    codex_whats_new "$codex_after"
  fi
fi

echo ""
ok "AI tools — done!"

# Footer
echo ""
if (( ${#FAILURES[@]} == 0 )); then
  echo "${BOLD}${GREEN}┌──────────────────────────────────────────────┐${RESET}"
  echo "${BOLD}${GREEN}│           ✓  All updates complete!           │${RESET}"
  echo "${BOLD}${GREEN}└──────────────────────────────────────────────┘${RESET}"
  echo ""
else
  echo "${BOLD}${YELLOW}⚠  Completed with ${#FAILURES[@]} failed step(s):${RESET}"
  for f in "${FAILURES[@]}"; do
    echo "${YELLOW}   - ${f}${RESET}"
  done
  echo ""
  exit 1
fi
