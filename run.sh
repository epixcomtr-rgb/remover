#!/bin/sh
# Kurulum gerektirmeyen çalıştırıcı: ./run.sh [list|remove] [--dry-run] ...
# (python3 gerekir: sudo apt install python3)
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$DIR/remover-gui" "$@"  # arayüz; CLI için: python3 "$DIR/remover"
