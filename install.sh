#!/usr/bin/env bash
#
# DSH digital-persona one-line installer (Linux / macOS)
#
# Standard usage (public repo, target machine can reach GitHub):
#   curl -fsSL https://raw.githubusercontent.com/lomehong/dsh-persona/main/install.sh | bash
#
# Private repo / intranet: host this file and the repo tarball on any HTTP server
# (build with: git archive --format=tar.gz --prefix=dsh-persona-main/ -o dsh-persona.tar.gz HEAD),
# then run on the target machine (still one line):
#   export DSP_TARBALL_URL='http://<server>/dsh-persona.tar.gz'; curl -fsSL http://<server>/install.sh | bash
#
# Unattended: export DSP_SETUP_ARGS='--non-interactive --owner <name> --owner-title <title>'
#
set -euo pipefail

printf '\n=== DSH digital-persona : one-line install ===\n\n'

OS="$(uname)"
case "$OS" in
  Linux|Darwin) ;;
  *) printf '  [X] unsupported OS: %s (use install.ps1 on Windows)\n' "$OS"; exit 1 ;;
esac

ROOT_DIR="$HOME/dsh-persona"
REPO_DIR="$ROOT_DIR/dsh-persona"

get_tarball_url() {
  if [[ -n "${DSP_TARBALL_URL:-}" ]]; then printf '%s' "$DSP_TARBALL_URL"; return; fi
  printf '%s' "https://codeload.github.com/lomehong/dsh-persona/tar.gz/refs/heads/main"
}

# running inside the repo (or with the repo as CWD): skip download, go straight to setup
SETUP=""
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SELF_DIR" && -f "$SELF_DIR/scripts/setup.sh" ]]; then
  SETUP="$SELF_DIR/scripts/setup.sh"
else
  TARBALL="$(get_tarball_url)"
  TGZ="$(mktemp -d)/dsh-persona-install.tar.gz"
  printf '  -> downloading package: %s\n' "$TARBALL"
  curl -fsSL --max-time 300 -o "$TGZ" "$TARBALL"

  printf '  -> extracting...\n'
  EXTRACT="$(mktemp -d)"
  tar -xzf "$TGZ" -C "$EXTRACT"

  # accept both layouts: codeload tarball has a dsh-persona-main/ prefix,
  # a local git archive may not; locate the repo root by scripts/setup.sh
  REPO_SRC=""
  if [[ -f "$EXTRACT/scripts/setup.sh" ]]; then
    REPO_SRC="$EXTRACT"
  else
    for d in "$EXTRACT"/*/; do
      [[ -f "$d/scripts/setup.sh" ]] && { REPO_SRC="${d%/}"; break; }
    done
  fi
  if [[ -z "$REPO_SRC" ]]; then
    printf '  [X] package invalid (scripts/setup.sh not found)\n'; exit 1
  fi

  mkdir -p "$ROOT_DIR"
  [[ -d "$REPO_DIR" ]] && rm -rf "$REPO_DIR"
  mv "$REPO_SRC" "$REPO_DIR"
  rm -rf "$(dirname "$TGZ")" "$EXTRACT"
  SETUP="$REPO_DIR/scripts/setup.sh"
fi

printf '  [OK] package ready, entering setup wizard (press Enter for defaults)\n\n'

# When piped (curl | bash), stdin is the script itself: re-attach the terminal
# so the interactive wizard can read user input.
if [[ $# -eq 0 && -n "${DSP_SETUP_ARGS:-}" ]]; then
  # shellcheck disable=SC2086
  set -- $DSP_SETUP_ARGS
fi
if [[ -t 0 ]]; then
  exec bash "$SETUP" "$@"
else
  exec bash "$SETUP" "$@" < /dev/tty
fi
