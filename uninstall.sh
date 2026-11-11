#!/usr/bin/env bash
# remover kaldırma betiği
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Sudo ile çalıştırın: sudo ./uninstall.sh" >&2
  exit 1
fi

rm -f /usr/local/bin/remover /usr/local/bin/remover-gui /usr/share/applications/remover.desktop
rm -rf /usr/local/lib/remover
rm -rf /etc/remover
command -v update-desktop-database >/dev/null && update-desktop-database >/dev/null 2>&1 || true
echo "✔ remover kaldırıldı (günlükler ~/.local/state/remover altında bırakıldı)."
