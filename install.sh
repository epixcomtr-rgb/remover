#!/usr/bin/env bash
# remover kurulum betiği
#   sudo ./install.sh          → /usr/local/bin/remover + /etc/remover/remover.conf + uygulama kısayolu
#   ./install.sh --user        → ~/.local/bin/remover (sudo gerekmez)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/remover"
CONF="$HERE/remover.conf"
MODE="${1:-system}"

[[ -f "$APP" ]] || { echo "remover dosyası bulunamadı: $APP" >&2; exit 1; }
chmod +x "$APP"

if [[ "$MODE" == "--user" ]]; then
  TARGET="$HOME/.local/bin"
  mkdir -p "$TARGET"
  install -m 755 "$APP" "$TARGET/remover"
  install -m 755 "$HERE/remover-gui" "$TARGET/remover-gui"
  mkdir -p "$HOME/.config/remover"
  [[ -f "$HOME/.config/remover/remover.conf" ]] || install -m 644 "$CONF" "$HOME/.config/remover/remover.conf"
  echo "✔ Kuruldu: $TARGET/remover"
  echo "  Kullanım: remover-gui      (onay kutulu arayüz)"
  echo "            remover          (uçbirim: listele/seç/sil)"
  echo "            remover list     (sadece listele)"
  case ":$PATH:" in
    *":$TARGET:"*) ;;
    *) echo "  Not: $TARGET PATH'te değil → ~/.profile dosyasına ekleyin:"
       echo '       export PATH="$HOME/.local/bin:$PATH"' ;;
  esac
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || { echo "Sistem kurulumu için: sudo ./install.sh   (ya da ./install.sh --user)" >&2; exit 1; }

install -m 755 "$APP" /usr/local/bin/remover
install -Dm755 "$APP" /usr/local/lib/remover/remover
install -m 755 "$HERE/remover-gui" /usr/local/bin/remover-gui
mkdir -p /etc/remover
if [[ -f /etc/remover/remover.conf ]]; then
  echo "• Mevcut /etc/remover/remover.conf korundu"
else
  install -m 644 "$CONF" /etc/remover/remover.conf
  echo "• Yapılandırma: /etc/remover/remover.conf"
fi

# Masaüstü kısayolu (terminalde açılır)
cat > /usr/share/applications/remover.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Remover
Comment=Kurulu programları listele ve seçerek kaldır
Exec=remover-gui
Icon=user-trash
Terminal=false
Categories=System;Utility;
Keywords=remove;uninstall;temizlik;kaldır;
DESK
chmod 644 /usr/share/applications/remover.desktop
command -v update-desktop-database >/dev/null && update-desktop-database >/dev/null 2>&1 || true

echo "✔ Kuruldu: /usr/local/bin/remover"
echo
echo "Kullanım:"
echo "  remover             # listele → numara seç → onayla → sil"
echo "  remover list        # sadece listele"
echo "  remover --dry-run   # hiçbir şey silmeden planı göster"
echo "  remover list --json # makine okunur çıktı"
