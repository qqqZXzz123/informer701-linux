#!/bin/bash
# qemu-test.sh - автоматическая проверка готового образа Debian 12 (Bookworm) armhf
# в эмуляторе QEMU (qemu-system-arm -M cubieboard, Cortex-A8, 512 МиБ ОЗУ).
#
# Загружает реальное ядро 6.6 (prebuilt/zImage) и РЕАЛЬНЫЙ systemd PID 1 с
# временной разреженной копии SD-образа в /dev/shm или /tmp (сам финальный образ
# $COPYTO/informer701-${BUILD}.img.xz остаётся неизменным и чистым).
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-debian}"
COPYTO="${COPYTO:-/tmp/out-debian}"
IMG_XZ="${IMG_XZ:-$COPYTO/informer701-${BUILD}.img.xz}"
SAVE_LOG="${SAVE_LOG:-$COPYTO/qtest-pass.log}"
ZIMAGE="${ZIMAGE:-$HERE/prebuilt/zImage}"
# В QEMU cubieboard нет физического чипа AXP209 на TWI0 -> используем вариант noaxp.dtb,
# идентичный по всем остальным узлам базовому DTB Informer 701.
DTB="${DTB:-$HERE/prebuilt/noaxp.dtb}"
TIMEOUT="${TIMEOUT:-300}"
QEMU_MEM="${QEMU_MEM:-512M}"

command -v qemu-system-arm >/dev/null || {
    echo "нужен пакет qemu-system-arm" >&2
    exit 1
}

if [ ! -f "$IMG_XZ" ]; then
    echo "=== [0] образ $IMG_XZ не найден - запускаю сборку build-image.sh ==="
    BUILD="$BUILD" COPYTO="$COPYTO" "$HERE/scripts/build-image.sh"
fi

# Используем /dev/shm если в нём свободно >= 450 МиБ, иначе /tmp (переносимость с Docker/CI)
SHM_FREE=$(df -Pm /dev/shm 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
if [ "${SHM_FREE:-0}" -ge 450 ]; then
    QBASE=/dev/shm
else
    QBASE="${TMPDIR:-/tmp}"
fi

QWORK=$(mktemp -d "$QBASE/informer701-qtest.XXXXXX")
LOG="$QWORK/qemu.log"
QIMG="$QWORK/sd.img"
MNT="$QWORK/mnt"

cleanup() {
    set +e
    [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null || true
    if mountpoint -q "$MNT" 2>/dev/null; then
        as_root umount -lf "$MNT" 2>/dev/null || true
    fi
    as_root rm -rf "$QWORK"
}
trap cleanup EXIT

echo "=== [1/3] подготовка разреженной копии образа ($IMG_XZ -> $QIMG) ==="
xz -dc "$IMG_XZ" | cp --sparse=always /dev/stdin "$QIMG"

# Смещение второго раздела (rootfs ext4) = 65 МиБ = 68157440 байт
ROOT_OFFSET=$((65 * 1024 * 1024))
mkdir -p "$MNT"
as_root mount -o loop,offset="$ROOT_OFFSET" "$QIMG" "$MNT"

# Устанавливаем в тестовую копию одноразовый сервис самопроверки после multi-user.target
as_root install -m 0755 "$HERE/scripts/qtest-init.sh" "$MNT/usr/local/sbin/qtest-runner"
as_root tee "$MNT/etc/systemd/system/informer701-qtest.service" >/dev/null <<'EOF'
[Unit]
Description=Informer 701 Automated QEMU Self-Test
After=multi-user.target informer701-zram.service dropbear.service haveged.service informer701-usbnet.service informer701-wifi.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qtest-runner
StandardOutput=null
StandardError=null
TimeoutStartSec=240s
EOF
as_root ln -sf /etc/systemd/system/informer701-qtest.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/informer701-qtest.service"
# Отключаем интерактивный agetty на ttyS0 только на время автотеста, чтобы приглашение
# входа не перемешивалось с выводом qtest-runner (конфиг serial-getty проверяется тестом).
as_root rm -f "$MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

as_root umount "$MNT"

echo "=== [2/3] запуск QEMU (cubieboard / Cortex-A8 / $QEMU_MEM / systemd PID 1, таймаут ${TIMEOUT}с) ==="
qemu-system-arm \
    -M cubieboard \
    -cpu cortex-a8 \
    -m "$QEMU_MEM" \
    -display none \
    -no-reboot \
    -monitor none \
    -serial file:"$LOG" \
    -kernel "$ZIMAGE" \
    -dtb "$DTB" \
    -drive file="$QIMG",format=raw,if=sd \
    -append "console=ttyS0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw panic=5 net.ifnames=0 systemd.show_status=true" \
    </dev/null >"$QWORK/qemu.err" 2>&1 &
QPID=$!

ELAPSED=0
while kill -0 "$QPID" 2>/dev/null; do
    if grep -q 'QTEST_RESULT:' "$LOG" 2>/dev/null; then
        sleep 1
        kill "$QPID" 2>/dev/null || true
        break
    fi
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "ТАЙМАУТ (${TIMEOUT} с) - останавливаю QEMU" >&2
        kill -9 "$QPID" 2>/dev/null || true
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
wait "$QPID" 2>/dev/null || true

echo "=== [3/3] вывод гостевой системы (${ELAPSED} с) ==="
[ -s "$QWORK/qemu.err" ] && { echo "--- stderr QEMU ---"; cat "$QWORK/qemu.err"; }
[ -f "$LOG" ] && cat "$LOG"
echo ""

if [ -n "${SAVE_LOG:-}" ] && [ -f "$LOG" ]; then
    mkdir -p "$(dirname "$SAVE_LOG")"
    cp "$LOG" "$SAVE_LOG"
    if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        chown "${SUDO_UID}:${SUDO_GID}" "$SAVE_LOG" 2>/dev/null || true
    fi
fi

if grep -q 'QTEST_RESULT: PASS' "$LOG"; then
    echo ">>> ИТОГ QEMU: УСПЕХ <<<"
    exit 0
else
    echo ">>> ИТОГ QEMU: ПРОВАЛ <<<" >&2
    exit 1
fi
