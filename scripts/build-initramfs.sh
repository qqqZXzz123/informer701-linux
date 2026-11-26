#!/bin/bash
# build-initramfs.sh - пересборка аварийного RAM-диска rescue.cpio.gz
# (используется только при вызове `bootnext rescue` со сломанной ФС на SD-карте).
# Сборка выполняется в /tmp, обновляя в образе новые скрипты и devmem2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/out-debian/rescue.cpio.gz}"
BASE_CPIO="${BASE_CPIO:-$HERE/prebuilt/rescue2.cpio.gz}"

case "$OUT" in
    "$HERE"|"$HERE"/*)
        echo "ОШИБКА: выходной файл ($OUT) не должен лежать внутри репозитория ($HERE)" >&2
        exit 1 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rescue-initrd.XXXXXX")
trap 'sudo rm -rf "$WORK"' EXIT

mkdir -p "$WORK/root" "$(dirname "$OUT")"
# Распаковываем базовый аварийный образ от root (для сохранения dev/* узлов при наличии прав)
if [ "$(id -u)" -eq 0 ]; then
    gzip -dc "$BASE_CPIO" | (cd "$WORK/root" && cpio -idm --quiet 2>/dev/null || true)
else
    sudo bash -c "gzip -dc '$BASE_CPIO' | (cd '$WORK/root' && cpio -idm --quiet 2>/dev/null || true)"
fi

# Обновляем диагностические скрипты в аварийном образе (в rescue /bin/sh - busybox ash,
# поэтому проверяем наличие /bin/bash или создаём совместимый симлинк /bin/bash -> /bin/sh
# для базовых утилит аварийного режима).
sudo bash -c "
    [ -e '$WORK/root/bin/bash' ] || ln -sf /bin/sh '$WORK/root/bin/bash'
    for s in clk regs i2cbus pmic pmic-regs pmic-vbus whichboot info; do
        [ -f '$HERE/rootfs-files/usr-local-bin/'\$s ] && \
            install -m 0755 '$HERE/rootfs-files/usr-local-bin/'\$s '$WORK/root/usr/local/bin/'\$s
    done
    (cd '$WORK/root' && find . -print0 | cpio --null -o -H newc --quiet | gzip -9) > '$OUT'
"
sudo chown "$(id -u):$(id -g)" "$OUT"
echo "[initramfs] готов: $OUT ($(du -sh "$OUT" | cut -f1))"
