#!/bin/zsh
set -euo pipefail
pwsh -File "${0:A:h}/pimelim.ps1" "$@"
