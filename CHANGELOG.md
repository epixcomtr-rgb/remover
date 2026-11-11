# Değişiklik günlüğü / Changelog

## 1.1.0 — 2026-11-11
- **Yeni:** GTK4 + libadwaita arayüzü (`remover-gui`) — onay kutulu liste, arama,
  tümünü seç/temizle, canlı boyut toplamı, komut günlüğü, tek yetki penceresi.
- **Yeni:** `REMOVER_DRY_RUN=1` / `--dry-run` ile arayüzde de silmeden plan görme.
- **Yeni:** `.deb` paketi (masaüstü girdisi + man sayfası), taşınabilir tar.gz, tek dosya sürümü.
- **Hız:** APT taraması tek `dpkg-query` çağrısına indirildi (123 paket için ~3s → ~1s).
- **Düzeltme:** Snap `gnome-*` runtime etiketleri; apt çekirdek paketleri korumalı listeye eklendi.
- **README:** İngilizce, Türkçe ve Çince.

## 1.0.0 — 2026-11-11
- İlk sürüm: APT/Snap/Flatpak/Docker/AppImage/kısayol taraması, numaralı liste,
  aralık seçimi, toplu kaldırma, korumalı paket listesi, `--json`, günlük.
