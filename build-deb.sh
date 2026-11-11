#!/usr/bin/env bash
# remover .deb paketi üretir  →  remover_1.0.0_all.deb
# Kullanım: ./build-deb.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.1.0"
PKG="remover"
ARCH="all"
ROOT="$HERE/build/${PKG}_${VERSION}_${ARCH}"
OUT="$HERE/${PKG}_${VERSION}_${ARCH}.deb"

command -v dpkg-deb >/dev/null || { echo "dpkg-deb bulunamadı" >&2; exit 1; }
[[ -f "$HERE/remover" ]] || { echo "remover dosyası yok" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" \
         "$ROOT/usr/bin" \
         "$ROOT/usr/lib/remover" \
         "$ROOT/etc/remover" \
         "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/doc/$PKG" \
         "$ROOT/usr/share/man/man1"

# --- programlar ---
install -m 755 "$HERE/remover" "$ROOT/usr/bin/remover"
install -m 755 "$HERE/remover" "$ROOT/usr/lib/remover/remover"      # GUI çekirdeği
install -m 755 "$HERE/remover-gui" "$ROOT/usr/bin/remover-gui"

# --- yapılandırma (conffile) ---
install -m 644 "$HERE/remover.conf" "$ROOT/etc/remover/remover.conf"

# --- masaüstü kısayolu ---
cat > "$ROOT/usr/share/applications/remover.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Remover
GenericName=Program Kaldırıcı
Name[tr]=Remover — Program Kaldırıcı
Comment=List installed programs and remove the ones you pick
Comment[tr]=Kurulu programları listeleyip seçtiklerinizi kaldırır
Exec=remover-gui
Icon=user-trash
Terminal=false
Categories=Utility;
Keywords=remove;uninstall;cleanup;kaldır;temizlik;
DESK
chmod 644 "$ROOT/usr/share/applications/remover.desktop"

# --- dokümantasyon ---
install -m 644 "$HERE/README.md" "$ROOT/usr/share/doc/$PKG/README.md"
cat > "$ROOT/usr/share/doc/$PKG/changelog" <<CHG
remover ($VERSION) unstable; urgency=medium

  * İlk sürüm: APT/Snap/Flatpak/Docker/AppImage/kısayol taraması,
    numaralı liste, toplu kaldırma, korumalı paket listesi, dry-run ve günlük.

 -- Ayku Altunoluk <aykut@localhost>  $(date -R)
CHG
gzip -9n "$ROOT/usr/share/doc/$PKG/changelog"
cat > "$ROOT/usr/share/doc/$PKG/copyright" <<'CPR'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: remover
Files: *
Copyright: 2026 Ayku Altunoluk
License: MIT
CPR
chmod 644 "$ROOT/usr/share/doc/$PKG/copyright"

# --- man sayfası ---
cat > "$ROOT/usr/share/man/man1/remover.1" <<'MAN'
.TH REMOVER 1 "2026-11-11" "remover 1.0.0" "Kullanıcı Komutları"
.SH ADI
remover \- kurulu programları listeleyip seçilenleri topluca kaldırır
.SH KULLANIM
.B remover
[\fBlist\fR|\fBremove\fR] [\fB\-\-json\fR] [\fB\-\-dry\-run\fR] [\fB\-\-no\-autoremove\fR]
[\fB\-\-force\-protected\fR] [\fB\-\-protected\-only\fR]
.SH AÇIKLAMA
APT (elle kurulan uygulamalar), Snap, Flatpak, Docker imajları, AppImage dosyaları ve
kullanıcı .desktop kısayollarını numaralı bir liste hâlinde gösterir; numara veya aralık
seçerek toplu kaldırma yapar.
.SH SEÇİM SÖZDİZİMİ
.TP
.B 3
tek öğe
.TP
.B 1,4,9
birden fazla öğe
.TP
.B 10-15
aralık
.TP
.B all
korumalı olmayan tüm öğeler
.TP
.B q
çıkış
.SH DOSYALAR
.TP
.I /etc/remover/remover.conf
Kaldırılması yasak paketler listesi
.TP
.I ~/.local/state/remover/*.log
İşlem günlükleri
.SH GÜVENLİK
Onay için \fBSIL\fR yazılması zorunludur. Korumalı paketler
\fB\-\-force\-protected\fR verilmedikçe asla kaldırılmaz.
.SH ÖRNEK
.EX
  remover list
  remover --dry-run
  remover
.EE
MAN
chmod 644 "$ROOT/usr/share/man/man1/remover.1"
gzip -9n "$ROOT/usr/share/man/man1/remover.1"

# --- control ---
INSTALLED_KB=$(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)
cat > "$ROOT/DEBIAN/control" <<CTRL
Package: $PKG
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Depends: python3 (>= 3.8), python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1
Recommends: x-terminal-emulator, pkexec | sudo
Installed-Size: $INSTALLED_KB
Maintainer: Ayku Altunoluk <aykut@localhost>
Homepage: https://www.schwarzhorse.com
Description: kurulu programlari onay kutulariyla listeleyip topluca kaldirir
 Remover; APT ile elle kurulan uygulamalari, Snap/Flatpak paketlerini,
 Docker imajlarini, AppImage dosyalarini ve kullanici .desktop kisayollarini
 GTK4/libadwaita arayuzunde onay kutulariyla listeler; isaretlenenler tek
 dugmeyle kaldirilir. Korunan paketler (sistem, apache/mysql/postgres/php,
 docker, tailscale vb.) varsayilan olarak silinemez. Komut satiri surumu
 (remover) ve --dry-run secenegi de paket icindedir.
CTRL
chmod 644 "$ROOT/DEBIAN/control"

# --- betikler ---
cat > "$ROOT/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  chmod 755 /usr/bin/remover /usr/bin/remover-gui || true
  chmod 755 /usr/lib/remover/remover || true
  chmod 644 /etc/remover/remover.conf || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
  command -v mandb >/dev/null 2>&1 && mandb -q 2>/dev/null || true
fi
exit 0
POST
cat > "$ROOT/DEBIAN/postrm" <<'POST'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
fi
exit 0
POST
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

# --- derle ---
dpkg-deb --build --root-owner-group "$ROOT" "$OUT" >/dev/null
echo "✔ Paket üretildi: $OUT"
echo
dpkg-deb -I "$OUT" | sed -n '1,14p'
echo
echo "Kurulum:  sudo apt install $OUT"
echo "          (ya da)  sudo dpkg -i $OUT"
