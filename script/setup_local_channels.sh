#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME/Documents/Astra/Workspaces"
mkdir -p "$HOME/Documents/Astra Dev/Workspaces"
mkdir -p "$HOME/Library/Application Support/Astra"
mkdir -p "$HOME/Library/Application Support/AstraDev"
mkdir -p "$HOME/Library/Logs/Astra"
mkdir -p "$HOME/Library/Logs/AstraDev"

cat <<EOF
ASTRA local channels are ready.

Production:
  App name:      ASTRA
  Bundle ID:     com.coral.ASTRA
  Workspaces:    $HOME/Documents/Astra/Workspaces
  App Support:   $HOME/Library/Application Support/Astra
  Logs:          $HOME/Library/Logs/Astra
  Updates:       stable Sparkle feed

Development:
  App name:      ASTRA Dev
  Bundle ID:     com.coral.ASTRA.dev
  Workspaces:    $HOME/Documents/Astra Dev/Workspaces
  App Support:   $HOME/Library/Application Support/AstraDev
  Logs:          $HOME/Library/Logs/AstraDev
  Updates:       disabled

Use:
  ./script/build_and_run.sh
      launches ASTRA Dev

  ASTRA_CHANNEL=prod ./script/build_and_run.sh
      launches a production-shaped local bundle
EOF
