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

Updates Homebrew, Mac App Store, macOS, npm globals, and AI dev tools.

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

# ─── Homebrew & Mac App Store ─────────────────────────────────────────
if [[ $SKIP_BREW == false ]]; then
  if command -v brew &>/dev/null; then

    section "Updating Applications"
    step "Fetching latest Homebrew formulas & taps..."
    run "Homebrew update" brew update

    step "Upgrading Homebrew formulas..."
    run "Homebrew formula upgrade" brew upgrade

    if [[ $GREEDY == true ]]; then
      step "Upgrading casks (including self-updating apps)..."
      run "Cask upgrade (greedy)" brew upgrade --cask --greedy
    else
      step "Upgrading Homebrew casks..."
      run "Cask upgrade" brew upgrade --cask
    fi

    if command -v mas &>/dev/null; then
      step "Updating Mac App Store apps..."
      # macOS Tahoe (26) no longer indexes kMDItemAppStoreHasReceipt in Spotlight,
      # so mas thinks every App Store app is "unindexed" and re-warns on every run.
      # Disable mas's auto-index/warn behaviour (cosmetic only — upgrades still work).
      run "Mac App Store upgrade" env MAS_NO_AUTO_INDEX=1 mas upgrade
    fi

    section "Cleaning Up"
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
  run "npm self-update" npm install -g npm --silent
  step "Updating global packages..."
  run "npm global package update" npm update -g --silent
  echo ""
  ok "npm — done!"
fi

# ─── AI Developer Tools ───────────────────────────────────────────────
section "Updating AI Developer Tools"

if command -v claude &>/dev/null; then
  step "Updating Claude Code..."
  claude update 2>&1 | grep -vE "^$" | while IFS= read -r line; do
    echo "  $line"
  done
  (( ${pipestatus[1]} != 0 )) && fail "Claude Code update"
fi

if command -v npm &>/dev/null && npm list -g --depth=0 2>/dev/null | grep -q "@openai/codex"; then
  step "Updating Codex CLI..."
  codex_before=$(codex --version 2>/dev/null | awk '{print $2}')
  npm install -g @openai/codex@latest --silent || fail "Codex CLI update"
  codex_after=$(codex --version 2>/dev/null | awk '{print $2}')
  if [[ "$codex_before" == "$codex_after" ]]; then
    echo "  Codex CLI is up to date ($codex_after)"
  else
    echo "  Codex CLI updated: $codex_before → $codex_after"
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
