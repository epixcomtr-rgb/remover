#!/bin/sh
# remover tek dosya sürümü — kurulum gerekmez:  sh remover-standalone.sh list
PY=$(command -v python3 || command -v python)
[ -n "$PY" ] || { echo "python3 bulunamadı: sudo apt install python3"; exit 1; }
exec "$PY" - "$@" <<'REMOVER_PY_EOF'
"""
remover — Ubuntu'da kurulu programları numaralı listeler, seçtiklerini toplu kaldırır.

Kaynaklar : APT (elle kurulan uygulamalar), Snap, Flatpak, Docker imajları,
            AppImage dosyaları, kullanıcı .desktop kısayolları
Kullanım  : remover            (etkileşimli: listele → seç → onayla → sil)
            remover list       (sadece listele)
            remover list --json
            remover --dry-run  (silmeden planı göster)
            remover --help

Güvenlik  : /etc/remover/remover.conf (ya da ./remover.conf) içindeki
            korumalı paketler asla kaldırılmaz.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

VERSION = "1.0.0"
HOME = Path.home()
LOG_DIR = HOME / ".local" / "state" / "remover"
CONF_PATHS = [
    Path("/etc/remover/remover.conf"),
    Path(__file__).resolve().parent / "remover.conf",
    HOME / ".config" / "remover" / "remover.conf",
]

# Kaldırılmaması gereken varsayılan paketler (config ile genişletilebilir)
DEFAULT_PROTECTED = {
    # sistem / masaüstü
    "ubuntu-desktop", "ubuntu-desktop-minimal", "ubuntu-session", "gnome-shell",
    "gnome-session", "gdm3", "systemd", "udev", "init", "login", "bash", "dash",
    "sudo", "apt", "dpkg", "snapd", "grub-efi-amd64", "grub-efi-amd64-signed",
    "shim-signed", "network-manager", "openssh-server", "xorg", "pipewire",
    "pulseaudio", "wireplumber", "kerneloops",
    # temel sistem araçları (elle kurulu görünse de kaldırılamaz)
    "coreutils", "util-linux", "bsdutils", "dash", "bash", "login", "adduser",
    "grep", "gzip", "tar", "sed", "findutils", "diffutils", "hostname",
    "ncurses-base", "ncurses-bin", "init-system-helpers", "mount", "e2fsprogs",
    "efibootmgr", "lm-sensors",
    # sunucu / altyapı
    "apache2", "mysql-server", "postgresql", "postgresql-contrib", "php",
    "php-curl", "php-gd", "php-json", "php-mbstring", "php-mysql", "php-zip",
    "tailscale", "cloudflared", "docker.io", "docker-compose-v2", "libvirt-daemon-system",
    "git", "nodejs", "npm", "golang-go", "ffmpeg",
}

# APT tarafında "uygulama" sayılmayan isim kalıpları
LIB_PATTERNS = [
    r"^lib", r"-dev$", r"-common$", r"-data$", r"-doc$", r"-dbg$", r"-headers$",
    r"^python3-", r"^gir1\.2-", r"^fonts?-", r"^font-", r"^language-pack-",
    r"^ubuntu-", r"^linux-", r"^xfonts-", r"^ibus-table-", r"^m17n-",
]

# Snap çalışma zamanları (uygulama değil; kaldırılırsa diğer snap'ler bozulur)
SNAP_RUNTIME_RE = re.compile(
    r"^(core\d*|bare|gnome-[\d.\-a-z]+|mesa-\d+|gtk-common-themes|wine-platform.*|"
    r"gaming-graphics-core\d+|chromium-ffmpeg|snapd.*)$"
)

C = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "red": "\033[31m", "green": "\033[32m", "yellow": "\033[33m",
    "blue": "\033[34m", "magenta": "\033[35m", "cyan": "\033[36m",
}


def color(text: str, *names: str) -> str:
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        return text
    return "".join(C.get(n, "") for n in names) + text + C["reset"]


def human(mb: float) -> str:
    if mb >= 1024:
        return f"{mb / 1024:.1f} GB"
    return f"{mb:.0f} MB" if mb >= 1 else "<1 MB"


def run(cmd: list[str], check: bool = False, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


# --------------------------------------------------------------------------- model
@dataclass
class Item:
    number: int
    name: str            # teknik ad (paket/snap/imaj adı)
    label: str           # ekranda görünen açıklama
    source: str          # apt | snap | flatpak | docker | appimage | desktop
    size_mb: float = 0.0
    note: str = ""
    protected: bool = False
    runtime: bool = False
    extra: dict = field(default_factory=dict)

    @property
    def kind(self) -> str:
        return {
            "apt": "APT", "snap": "SNAP", "flatpak": "FLATPAK",
            "docker": "DOCKER", "appimage": "APPIMAGE", "desktop": "KISAYOL",
        }.get(self.source, self.source.upper())


# --------------------------------------------------------------------------- config
def load_config() -> set[str]:
    protected = set(DEFAULT_PROTECTED)
    for path in CONF_PATHS:
        try:
            if not path.is_file():
                continue
            for raw in path.read_text(encoding="utf8").splitlines():
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if "=" in line:                     # anahtar=değer biçimi
                    key, _, val = line.partition("=")
                    if key.strip() != "protected":
                        continue
                    line = val
                protected.update(p.strip() for p in line.replace(",", " ").split() if p.strip())
            break
        except OSError:
            continue
    return protected


# --------------------------------------------------------------------------- collectors
def collect_apt(protected: set[str]) -> list[Item]:
    if not shutil.which("apt-mark") or not shutil.which("dpkg-query"):
        return []
    manual = run(["apt-mark", "showmanual"]).stdout.split()
    items: list[Item] = []
    for pkg in sorted(set(manual)):
        if any(re.search(p, pkg) for p in LIB_PATTERNS):
            continue
        out = run(["dpkg-query", "-W", "-f=${Installed-Size}\t${binary:Summary}", pkg]).stdout.strip()
        size, _, summary = out.partition("\t")
        try:
            size_mb = int(size) / 1024
        except ValueError:
            size_mb = 0.0
        items.append(Item(0, pkg, summary or pkg, "apt", size_mb,
                          protected=pkg in protected))
    items.sort(key=lambda i: (-i.size_mb, i.name))
    return items


def collect_snap(protected: set[str]) -> list[Item]:
    if not shutil.which("snap"):
        return []
    items: list[Item] = []
    snaps_dir = Path("/var/lib/snapd/snaps")
    for line in run(["snap", "list"]).stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        name, version, _rev, _chan, publisher = parts[0], parts[1], parts[2], parts[3], parts[4]
        size_mb = 0.0
        try:
            for snap_file in snaps_dir.glob(f"{name}_*.snap"):
                size_mb += snap_file.stat().st_size / 1024 / 1024
        except OSError:
            pass
        items.append(Item(0, name, f"{name} {version} ({publisher})", "snap", size_mb,
                          protected=name in protected,
                          runtime=bool(SNAP_RUNTIME_RE.match(name))))
    items.sort(key=lambda i: (i.runtime, -i.size_mb, i.name))
    return items


def collect_flatpak(protected: set[str]) -> list[Item]:
    if not shutil.which("flatpak"):
        return []
    out = run(["flatpak", "list", "--columns=application,name,size"]).stdout
    items: list[Item] = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) < 2 or not parts[0]:
            continue
        app_id, name = parts[0], parts[1]
        size_mb = 0.0
        if len(parts) >= 3 and parts[2]:
            m = re.match(r"([\d.,]+)\s*([kKmMgG]?B?)", parts[2])
            if m:
                val = float(m.group(1).replace(",", "."))
                unit = m.group(2).lower()
                size_mb = val / 1024 if unit.startswith("k") else \
                          val * 1024 if unit.startswith("g") else val
        items.append(Item(0, app_id, f"{name or app_id}", "flatpak", size_mb,
                          protected=app_id in protected))
    items.sort(key=lambda i: (-i.size_mb, i.name))
    return items


def collect_docker(protected: set[str]) -> list[Item]:
    if not shutil.which("docker"):
        return []
    out = run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}"])
    if out.returncode != 0:
        return []
    items: list[Item] = []
    for line in out.stdout.splitlines():
        ref, _, size = line.partition("\t")
        if not ref or ref == "<none>:<none>":
            continue
        m = re.match(r"([\d.]+)\s*([kKmMgG]?B)", size.strip())
        size_mb = 0.0
        if m:
            val, unit = float(m.group(1)), m.group(2).lower()
            size_mb = val / 1024 if unit.startswith("k") else val * 1024 if unit.startswith("g") else val
        items.append(Item(0, ref, f"{ref}", "docker", size_mb, protected=False))
    items.sort(key=lambda i: (-i.size_mb, i.name))
    return items


def collect_appimages(protected: set[str]) -> list[Item]:
    roots = [HOME, HOME / "Applications", HOME / "Downloads", HOME / "İndirilenler",
             HOME / "Masaüstü", HOME / "Desktop", HOME / "opt"]
    seen: set[Path] = set()
    items: list[Item] = []
    for root in roots:
        if not root.is_dir():
            continue
        for path in root.glob("*.AppImage"):
            real = path.resolve()
            if real in seen:
                continue
            seen.add(real)
            try:
                size_mb = real.stat().st_size / 1024 / 1024
            except OSError:
                size_mb = 0.0
            items.append(Item(0, real.name, str(real), "appimage", size_mb))
    items.sort(key=lambda i: (-i.size_mb, i.name))
    return items


def collect_desktop_shortcuts(protected: set[str]) -> list[Item]:
    app_dir = HOME / ".local" / "share" / "applications"
    if not app_dir.is_dir():
        return []
    items: list[Item] = []
    for path in sorted(app_dir.glob("*.desktop")):
        try:
            text = path.read_text(encoding="utf8", errors="replace")
        except OSError:
            continue
        name = ""
        for line in text.splitlines():
            if line.startswith("Name=") and not name:
                name = line[5:].strip()
        if not name:
            continue
        # chrome-*.desktop dosyaları web uygulaması kısayollarıdır: yalnızca kısayol silinir
        items.append(Item(0, name, path.name, "desktop", 0.0,
                          note="yalnızca kısayol dosyası silinir",
                          extra={"path": str(path)}))
    return items


def collect_all(protected: set[str]) -> list[Item]:
    groups = [
        collect_apt(protected),
        collect_snap(protected),
        collect_flatpak(protected),
        collect_docker(protected),
        collect_appimages(protected),
        collect_desktop_shortcuts(protected),
    ]
    items: list[Item] = []
    for group in groups:
        for it in group:
            it.number = len(items) + 1
            items.append(it)
    return items


# --------------------------------------------------------------------------- listing
def print_list(items: list[Item]) -> None:
    if not items:
        print("Listelenecek program bulunamadı.")
        return
    total = sum(i.size_mb for i in items)
    print()
    print(color(f"  remover {VERSION}", "bold", "cyan")
          + color(f"  ·  {len(items)} öğe  ·  toplam {human(total)}", "dim"))
    print()
    header = f"{'#':>4}  {'KAYNAK':<8} {'BOYUT':>8}  {'AD':<34} AÇIKLAMA"
    print(color(header, "bold"))
    print(color("-" * 108, "dim"))
    last_source = None
    for it in items:
        if it.source != last_source:
            last_source = it.source
            print(color(f"  ── {it.kind} " + "─" * (100 - len(it.kind)), "dim"))
        size = human(it.size_mb) if it.size_mb else "—"
        name = it.name if len(it.name) <= 34 else it.name[:31] + "..."
        flags = []
        if it.protected:
            flags.append(color("KORUMALI", "red"))
        if it.runtime:
            flags.append(color("runtime", "yellow"))
        note = it.label if it.label != it.name else ""
        if len(note) > 44:
            note = note[:41] + "..."
        suffix = ("  " + " ".join(flags)) if flags else ""
        print(f"{it.number:>4}  {it.kind:<8} {size:>8}  {name:<34} {note}{suffix}")
    print()
    print(color(f"  Toplam tahmini kazanç: {human(total)}", "green"))
    print()


# --------------------------------------------------------------------------- selection
def parse_selection(text: str, items: list[Item]) -> list[Item]:
    text = text.strip().lower()
    if text in {"all", "tumu", "tümü", "*"}:
        return [i for i in items if not i.protected]
    chosen: dict[int, Item] = {}
    for chunk in re.split(r"[,\s]+", text):
        if not chunk:
            continue
        m = re.fullmatch(r"(\d+)\s*-\s*(\d+)", chunk)
        if m:
            lo, hi = sorted((int(m.group(1)), int(m.group(2))))
            for n in range(lo, hi + 1):
                if 1 <= n <= len(items):
                    chosen[n] = items[n - 1]
            continue
        if chunk.isdigit():
            n = int(chunk)
            if 1 <= n <= len(items):
                chosen[n] = items[n - 1]
            continue
        raise ValueError(f"anlaşılamayan seçim: {chunk!r}")
    return [chosen[n] for n in sorted(chosen)]


# --------------------------------------------------------------------------- removal
def need_sudo(items: list[Item]) -> bool:
    return any(i.source in {"apt", "snap", "flatpak"} for i in items)


def plan_lines(items: list[Item]) -> list[str]:
    lines = []
    for it in items:
        if it.source == "apt":
            lines.append(f"apt-get purge -y {it.name}")
        elif it.source == "snap":
            lines.append(f"snap remove --purge {it.name}")
        elif it.source == "flatpak":
            lines.append(f"flatpak uninstall -y {it.name}")
        elif it.source == "docker":
            lines.append(f"docker rmi {it.name}")
        elif it.source == "appimage":
            lines.append(f"rm -f {it.name}")
        elif it.source == "desktop":
            lines.append(f"rm -f {it.extra.get('path', it.name)}")
    return lines


def remove_apt(names: list[str], log) -> tuple[bool, str]:
    cmd = ["apt-get", "purge", "-y", "--autoremove"] + names
    log(f"$ sudo {' '.join(cmd)}")
    proc = subprocess.run(["sudo"] + cmd, text=True)
    return proc.returncode == 0, "apt"


def remove_snap(name: str, log) -> tuple[bool, str]:
    log(f"$ sudo snap remove --purge {name}")
    proc = subprocess.run(["sudo", "snap", "remove", "--purge", name], text=True)
    return proc.returncode == 0, "snap"


def remove_flatpak(app_id: str, log) -> tuple[bool, str]:
    log(f"$ flatpak uninstall -y {app_id}")
    proc = subprocess.run(["flatpak", "uninstall", "-y", app_id], text=True)
    return proc.returncode == 0, "flatpak"


def remove_docker(ref: str, log) -> tuple[bool, str]:
    log(f"$ docker rmi {ref}")
    proc = subprocess.run(["docker", "rmi", ref], text=True)
    return proc.returncode == 0, "docker"


def remove_path(path: str, log) -> tuple[bool, str]:
    """Dosya/kısayol siler; kısayol öğelerinde gerçek yolu kullanır."""
    p = Path(path)
    log(f"$ rm -f {p}")
    try:
        if p.exists():
            p.unlink()
        return True, "dosya"
    except OSError as exc:
        log(f"  hata: {exc}")
        return False, "dosya"


def execute(items: list[Item], dry_run: bool, autoremove: bool, log) -> dict:
    result = {"ok": [], "fail": [], "freed_mb": 0.0}
    apt_names = [i for i in items if i.source == "apt"]
    rest = [i for i in items if i.source != "apt"]

    if apt_names:
        if dry_run:
            log("[dry-run] apt paketleri kaldırılmayacak: " + ", ".join(i.name for i in apt_names))
        else:
            ok, _ = remove_apt([i.name for i in apt_names], log)
            for it in apt_names:
                (result["ok"] if ok else result["fail"]).append(it)
                if ok:
                    result["freed_mb"] += it.size_mb

    for it in rest:
        if dry_run:
            log(f"[dry-run] {it.kind}: {it.name}")
            result["ok"].append(it)
            result["freed_mb"] += it.size_mb
            continue
        if it.source == "snap":
            ok, _ = remove_snap(it.name, log)
        elif it.source == "flatpak":
            ok, _ = remove_flatpak(it.name, log)
        elif it.source == "docker":
            ok, _ = remove_docker(it.name, log)
        elif it.source == "desktop":
            ok, _ = remove_path(it.extra.get("path", it.name), log)
        else:
            ok, _ = remove_path(it.name, log)
        (result["ok"] if ok else result["fail"]).append(it)
        if ok:
            result["freed_mb"] += it.size_mb

    if apt_names and autoremove and not dry_run:
        log("$ sudo apt-get autoremove -y")
        subprocess.run(["sudo", "apt-get", "autoremove", "-y"], text=True)

    return result


# --------------------------------------------------------------------------- main flows
def do_list(args: argparse.Namespace) -> int:
    protected = load_config()
    items = collect_all(protected)
    if args.json:
        print(json.dumps([{
            "no": i.number, "source": i.source, "name": i.name, "label": i.label,
            "size_mb": round(i.size_mb, 1), "protected": i.protected, "runtime": i.runtime,
            "note": i.note,
        } for i in items], ensure_ascii=False, indent=2))
        return 0
    if args.protected_only:
        items = [i for i in items if i.protected]
    print_list(items)
    return 0


def do_interactive(args: argparse.Namespace) -> int:
    protected = load_config()
    items = collect_all(protected)
    if not items:
        print("Listelenecek program bulunamadı.")
        return 0
    print_list(items)

    while True:
        try:
            raw = input(color("Seçim (örn: 1,4,10-15 · tümü: all · çıkış: q) › ", "bold", "cyan"))
        except (EOFError, KeyboardInterrupt):
            print()
            return 130
        if raw.strip().lower() in {"q", "quit", "exit", "çık", "cik"}:
            print("İptal edildi.")
            return 0
        try:
            chosen = parse_selection(raw, items)
        except ValueError as exc:
            print(color(f"  ! {exc}", "red"))
            continue
        if not chosen:
            print(color("  ! Seçim boş.", "red"))
            continue
        break

    blocked = [i for i in chosen if i.protected]
    if blocked and not args.force_protected:
        print()
        print(color("  ! Korumalı öğeler seçildi, bunlar atlanacak:", "red"))
        for it in blocked:
            print(f"     #{it.number} {it.name}")
        chosen = [i for i in chosen if not i.protected]
        if not chosen:
            print("  Kaldırılacak öğe kalmadı.")
            return 1

    total = sum(i.size_mb for i in chosen)
    print()
    print(color("  Kaldırılacaklar:", "bold"))
    for it in chosen:
        print(f"    #{it.number:>3}  {it.kind:<8} {human(it.size_mb) if it.size_mb else '—':>8}  {it.name}")
    print(color(f"\n  Tahmini kazanç: {human(total)}", "green"))
    print(color("  Çalıştırılacak komutlar:", "dim"))
    for line in plan_lines(chosen):
        print(color("    " + line, "dim"))
    print()

    if args.dry_run:
        print(color("  --dry-run: hiçbir şey silinmedi.", "yellow"))
        return 0

    confirm_phrase = "SIL"
    try:
        answer = input(f"  Onaylamak için {color(confirm_phrase, 'bold', 'red')} yazın: ")
    except (EOFError, KeyboardInterrupt):
        print("\n  İptal edildi.")
        return 130
    if answer.strip() != confirm_phrase:
        print("  İptal edildi.")
        return 0

    if need_sudo(chosen) and os.geteuid() != 0:
        print(color("\n  sudo şifresi gerekebilir (APT/snap işlemleri için).", "yellow"))

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"remover-{datetime.now():%Y%m%d-%H%M%S}.log"
    with log_path.open("w", encoding="utf8") as fh:
        def log(msg: str) -> None:
            print(color("  " + msg, "dim"))
            fh.write(msg + "\n")
            fh.flush()

        log(f"remover {VERSION} · {datetime.now():%Y-%m-%d %H:%M:%S}")
        for it in chosen:
            log(f"seçildi: #{it.number} {it.kind} {it.name} ({human(it.size_mb)})")
        if args.autoremove is False:
            pass
        result = execute(chosen, False, args.autoremove, log)

    print()
    if result["ok"]:
        print(color(f"  ✔ Kaldırıldı: {len(result['ok'])} öğe · ~{human(result['freed_mb'])} boşaldı", "green", "bold"))
    if result["fail"]:
        print(color(f"  ✖ Başarısız: {len(result['fail'])} öğe", "red", "bold"))
        for it in result["fail"]:
            print(f"     #{it.number} {it.name}")
    print(color(f"  Günlük: {log_path}", "dim"))
    print()
    return 0 if not result["fail"] else 2


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="remover",
        description="Kurulu programları numaralı listeler ve seçilenleri toplu kaldırır.",
        epilog="Örnek: remover · remover list · remover --dry-run · remover list --json",
    )
    parser.add_argument("command", nargs="?", choices=["list", "remove"], default="remove",
                        help="list: sadece listele · remove (varsayılan): seç ve kaldır")
    parser.add_argument("--json", action="store_true", help="list çıktısını JSON ver")
    parser.add_argument("--protected-only", action="store_true", help="list: yalnızca korumalıları göster")
    parser.add_argument("--dry-run", action="store_true", help="silme, yalnızca planı göster")
    parser.add_argument("--no-autoremove", dest="autoremove", action="store_false",
                        help="APT sonrası autoremove çalıştırma")
    parser.add_argument("--force-protected", action="store_true",
                        help="korumalı listeyi yok say (riskli)")
    parser.add_argument("--version", action="version", version=f"remover {VERSION}")
    args = parser.parse_args(argv)

    if os.geteuid() == 0 and not os.environ.get("SUDO_USER"):
        print(color("  ! Uyarı: root olarak çalışıyorsunuz; kullanıcı olarak çalıştırmanız önerilir.", "yellow"))

    return do_list(args) if args.command == "list" else do_interactive(args)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
    except BrokenPipeError:
        os._exit(0)
REMOVER_PY_EOF
