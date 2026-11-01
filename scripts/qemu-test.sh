#!/bin/bash
# qemu-test.sh - прогон содержимого образа в QEMU (ARM cubieboard) перед выдачей.
#
#   BUILD=b021 bash scripts/qemu-test.sh
#   ROOTFS=/tmp/art-b021/rootfs LOG=/tmp/q.log bash scripts/qemu-test.sh
#
# Что делает: берёт ТОТ ЖЕ rootfs, из которого собран образ (по умолчанию
# /tmp/art-$BUILD/rootfs, его оставляет build-image.sh), кладёт в него /init из
# scripts/qtest-init.sh, пакует в initramfs и грузит наше ядро + lowopp.dtb.
# То есть проверяется содержимое образа, а не сборочного хоста.
#
# Результат: лог в $LOG, в конце "== QTEST RESULT: PASS|FAIL ==". Строки "FAIL:"
# - проваленные проверки. Код возврата 0 только при PASS.
#
# Таймаут: в QEMU всё в ~10 раз медленнее платы (i2c-транзакция ~2 с), полный
# прогон ~3-5 минут. Запускать фоном, а не из-под короткого таймаута bash.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-b021}"
ROOTFS="${ROOTFS:-/tmp/art-$BUILD/rootfs}"
Q="/tmp/qroot-$BUILD"
CPIO="/tmp/qtest-$BUILD.cpio.gz"
LOG="${LOG:-/tmp/qtest-$BUILD.log}"
TIMEOUT="${TIMEOUT:-900}"
DTB="${DTB:-$HERE/prebuilt/lowopp.dtb}"
KERNEL="${KERNEL:-$HERE/prebuilt/zImage}"

[ -d "$ROOTFS" ] || { echo "FATAL: нет rootfs $ROOTFS (сначала build-image.sh)" >&2; exit 2; }
[ -f "$KERNEL" ] || { echo "FATAL: нет ядра $KERNEL" >&2; exit 2; }
[ -f "$DTB" ]    || { echo "FATAL: нет DTB $DTB" >&2; exit 2; }
command -v qemu-system-arm >/dev/null || { echo "FATAL: нет qemu-system-arm" >&2; exit 2; }
command -v cpio >/dev/null || { echo "FATAL: нет cpio (apt-get install cpio)" >&2; exit 2; }

echo "== qemu-test $BUILD"
echo "   rootfs : $ROOTFS"
echo "   ядро   : $KERNEL"
echo "   dtb    : $DTB"
echo "   лог    : $LOG"

rm -rf "$Q"; mkdir -p "$Q"
cp -a "$ROOTFS/." "$Q/"
cp "$HERE/scripts/qtest-init.sh" "$Q/init"
chmod 755 "$Q/init"

(cd "$Q" && find . | LC_ALL=C cpio -o -H newc 2>/dev/null | gzip -1 > "$CPIO")
SZ=$(du -k "$CPIO" | cut -f1)
echo "   initramfs: $CPIO (${SZ} КБ)"
# без cpio в контейнере архив получается пустым (4 КБ) и тест "проходит" впустую
if [ "$SZ" -lt 1000 ]; then
    echo "FATAL: initramfs всего ${SZ} КБ - rootfs не упакован (нет cpio? пустой $Q?)" >&2
    exit 2
fi

# QEMU сам не выходит после poweroff гостя (у cubieboard нет обработчика
# выключения), поэтому ждём строку "== QTEST DONE ==" в логе и гасим процесс.
: > "$LOG"
qemu-system-arm \
    -M cubieboard -m "${MEM:-512}" -smp 1 -nographic -no-reboot \
    -kernel "$KERNEL" -dtb "$DTB" -initrd "$CPIO" \
    -append "console=ttyS0,115200 loglevel=4 clk_ignore_unused rdinit=/init panic=1" \
    > "$LOG" 2>&1 &
QPID=$!
RC=0
WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]; do
    sleep 5; WAITED=$((WAITED+5))
    if tr -d '\r' < "$LOG" 2>/dev/null | grep -q 'QTEST DONE'; then break; fi
    if ! kill -0 "$QPID" 2>/dev/null; then RC=1; break; fi
done
[ "$WAITED" -ge "$TIMEOUT" ] && echo "== ВНИМАНИЕ: таймаут $TIMEOUT с - тест не завершился"
kill -TERM "$QPID" 2>/dev/null; sleep 2; kill -KILL "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
echo "== прогон занял ~$WAITED с (qemu остановлен)"

echo
echo "-------------------- проваленные проверки --------------------"
if tr -d '\r' < "$LOG" | grep -q '^FAIL:'; then
    tr -d '\r' < "$LOG" | grep '^FAIL:' | head -40
else
    echo "  (нет строк FAIL:)"
fi
echo "----------------------- итог ---------------------------------"
tr -d '\r' < "$LOG" | grep -E 'QTEST RESULT|QTEST DONE|провалено проверок' || echo "  тест не дошёл до конца (см. $LOG)"

if tr -d '\r' < "$LOG" | grep -q 'QTEST RESULT: PASS'; then
    echo "== РЕЗУЛЬТАТ: PASS"
    exit 0
fi
echo "== РЕЗУЛЬТАТ: FAIL (полный лог: $LOG)"
exit 1
