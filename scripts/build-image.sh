#!/bin/bash
# Полная сборка SD-образа Informer 701 из готовых компонентов в prebuilt/.
# Ядро пересобирать НЕ нужно: zImage, все DTB, SPL/U-Boot, rescue-initramfs и
# архив модулей ядра лежат в prebuilt/ и проверены хешами (BUILD-*.txt).
#
#   BUILD=b021 bash scripts/build-image.sh [каталог-результата]
#
# Переменные окружения:
#   BUILD         номер сборки (имя файлов informer701-$BUILD.img*), по умолчанию b021
#   BOOT_DEFAULT  метка загрузки по умолчанию (lowopp)
#   MODULES_TGZ   архив модулей ядра (по умолчанию - самый свежий prebuilt/modules-*.tar.xz)
#   COPYTO        куда копировать .xz/.sha256 (по умолчанию корень рабочей папки)
#   TOTAL_MIB     размер образа (512)
#
# Что делает:
#   1. собирает каталог артефактов /tmp/art-$BUILD (zImage, DTB, SPL, rescue, модули);
#   2. готовит rootfs (prepare-rootfs.sh: пакеты из pkgs/, прошивки из firmware/,
#      модули, хелперы из rootfs-files/, inittab/rcS/local/motd, ключи dropbear);
#   3. собирает образ (make-sdimage.sh: MBR + vFAT boot + ext4 root + extlinux.conf);
#   4. кладёт .xz и .sha256 в корень рабочей папки (сырой .img - никогда).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"      # .../informer701-linux
WS="$(cd "$HERE/.." && pwd)"                  # корень рабочей папки
BUILD="${BUILD:-b021}"
BOOT_DEFAULT="${BOOT_DEFAULT:-lowopp}"
A="/tmp/art-$BUILD"
O="${1:-/tmp/out-$BUILD}"
COPYTO="${COPYTO:-$WS}"
ROOTFS_TGZ="$HERE/pkgs/alpine-minirootfs-3.20.9-armv7.tar.gz"
ROOT_PASS="${ROOT_PASS:-informer701}"

echo "== сборка $BUILD"
echo "   артефакты: $A"
echo "   результат: $O  (копия .xz/.sha256 -> $COPYTO)"

rm -rf "$A"; mkdir -p "$A" "$O"

# ------------------------------------------------------------ 1. артефакты
# обязательный минимум: ядро, U-Boot, rescue-инитрамfs и DTB пунктов меню
for f in zImage u-boot-sunxi-with-spl.bin rescue2.cpio.gz; do
    [ -f "$HERE/prebuilt/$f" ] || { echo "FATAL: нет prebuilt/$f" >&2; exit 1; }
    cp "$HERE/prebuilt/$f" "$A/"
done
for d in lowopp informer pinned flatvolt nocpufreq safe noaxp nommc wdt hdmi nousb; do
    [ -f "$HERE/prebuilt/$d.dtb" ] || { echo "FATAL: нет prebuilt/$d.dtb" >&2; exit 1; }
    cp "$HERE/prebuilt/$d.dtb" "$A/"
done
# необязательное: аварийное ядро b016 (пункт меню b016-lowopp) и старый rescue.
# Без них образ собирается и работает; пункт возврата просто не создаётся.
for f in zImage-b016 rescue.cpio.gz; do
    if [ -f "$HERE/prebuilt/$f" ]; then cp "$HERE/prebuilt/$f" "$A/"
    else echo "   (нет prebuilt/$f - пропускаю, необязательный файл)"; fi
done
if [ -f "$HERE/prebuilt/lowopp-b016.dtb" ]; then cp "$HERE/prebuilt/lowopp-b016.dtb" "$A/"
else echo "   (нет prebuilt/lowopp-b016.dtb - пункт b016-lowopp не создаётся)"; fi

# модули ядра: берём архив для этой сборки, иначе самый свежий
MODULES_TGZ="${MODULES_TGZ:-}"
if [ -z "$MODULES_TGZ" ]; then
    if [ -f "$HERE/prebuilt/modules-$BUILD.tar.xz" ]; then
        MODULES_TGZ="$HERE/prebuilt/modules-$BUILD.tar.xz"
    else
        MODULES_TGZ=$(ls -1t "$HERE"/prebuilt/modules-*.tar.xz 2>/dev/null | head -1 || true)
    fi
fi
MODROOT=""
if [ -n "$MODULES_TGZ" ] && [ -f "$MODULES_TGZ" ]; then
    MODROOT="/tmp/modroot-$BUILD"
    rm -rf "$MODROOT"; mkdir -p "$MODROOT"
    tar -xJf "$MODULES_TGZ" -C "$MODROOT"
    echo "   модули: $(basename "$MODULES_TGZ") -> $(find "$MODROOT" -name '*.ko*' | wc -l) шт."
else
    echo "   ВНИМАНИЕ: архив модулей не найден - образ будет БЕЗ модулей (WiFi не заработает)" >&2
fi

# ---------------------------------------------------------------- 2. rootfs
QEMU_ARM="$(command -v qemu-arm-static || true)" \
BUILD="$BUILD" BOOT_DEFAULT="$BOOT_DEFAULT" MODULES="$MODROOT" \
    bash "$HERE/scripts/prepare-rootfs.sh" "$ROOTFS_TGZ" "$A/rootfs" "$ROOT_PASS"

# ------------------------------------------------- 2b. проверка библиотек
# Пакеты кладутся в корень распаковкой .apk, поэтому легко потерять
# подпакеты-библиотеки (liblzma, libxtables, libmnl, libncursesw, ...): файлы на
# месте, а на плате команда молча не запускается. Так в первой версии b021
# оказались нерабочими modprobe и iptables - проверяем ДО создания образа.
echo "== проверка DT_NEEDED у всех ELF-файлов rootfs"
if ! python3 "$HERE/scripts/check-libs.py" "$A/rootfs"; then
    echo "FATAL: в rootfs не хватает библиотек (лечение: python3 scripts/fetch-apks.py)" >&2
    [ "${ALLOW_MISSING_LIBS:-0}" = "1" ] || exit 1
fi

# ------------------------------------------------ 2c. подпись regulatory.db
# Ядро 6.6 доверяет ТОЛЬКО ключу sforshee (net/wireless/certs/sforshee.hex), а
# wireless-regdb с 2024.01.23 подписывает wens -> в dmesg "loaded regulatory.db
# is malformed or signature is missing/invalid", база не применяется (мировой
# домен, каналы 12-13 закрыты, iw reg set не действует). Проверяем подпись.
if command -v openssl >/dev/null 2>&1 && [ -f "$HERE/certs/sforshee.x509.pem" ] \
   && [ -f "$A/rootfs/lib/firmware/regulatory.db" ]; then
    if openssl smime -verify -inform DER \
           -in  "$A/rootfs/lib/firmware/regulatory.db.p7s" \
           -content "$A/rootfs/lib/firmware/regulatory.db" \
           -CAfile "$HERE/certs/sforshee.x509.pem" -purpose any -out /dev/null >/dev/null 2>&1; then
        echo "== regulatory.db: подпись sforshee ВЕРНА (ядро её примет)"
    else
        echo "FATAL: regulatory.db.p7s не проверяется ключом sforshee - ядро отвергнет базу" >&2
        echo "       (см. docs/regulatory-db.md; нужен wireless-regdb <= 2023.09.01)" >&2
        [ "${ALLOW_BAD_REGDB:-0}" = "1" ] || exit 1
    fi
fi

# ----------------------------------------------------------------- 3. образ
BUILD="$BUILD" bash "$HERE/scripts/make-sdimage.sh" "$A" "$O" "$COPYTO"

echo "== готово: $O/informer701-$BUILD.img.xz"
ls -la "$O"/informer701-"$BUILD".img* "$O"/informer701-"$BUILD".sha256 2>/dev/null
