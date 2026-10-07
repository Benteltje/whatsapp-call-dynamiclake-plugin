#!/bin/zsh
set -euo pipefail
repo_dir=${0:A:h:h}
if [[ "${1:-}" != "--skip-build" ]]; then "$repo_dir/scripts/build.sh"; fi
binary="$repo_dir/build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor"
"$binary" --self-test
python3 "$repo_dir/tests/socket_integration.py" "$binary"
