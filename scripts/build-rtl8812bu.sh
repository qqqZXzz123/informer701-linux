#!/bin/bash
# build-rtl8812bu.sh
#
# Автономная кросс-сборка внешнего двухдиапазонного (2.4/5 ГГц, STA + AP hostapd)
# драйвера Realtek RTL8812BU / RTL8822BU (88x2bu.ko) для ядра 6.6.0 (kernel.config-b021)
# и упаковка модуля в prebuilt/modules-6.6.0-b021.tar.xz.
#
# Все временные исходники ядра и драйвера размещаются строго в /tmp и удаляются
# по завершении скрипта.
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/tmp/informer701-rtl8812bu}"
MODS_TAR="${MODS_TAR:-$HERE/prebuilt/modules-6.6.0-b021.tar.xz}"
KCONF="${KCONF:-$HERE/kernel/kernel.config-b021}"
CERT_PEM="${CERT_PEM:-$HERE/certs/sforshee.x509.pem}"
KVER="${KVER:-6.6}"
RTL88X2BU_REPO="${RTL88X2BU_REPO:-https://github.com/morrownr/88x2bu-20210702.git}"
JOBS="${JOBS:-$(nproc)}"

export ARCH=arm
export CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

case "$WORK" in
    "$HERE"|"$HERE"/*)
        echo "ОШИБКА: временный каталог ($WORK) не должен находиться внутри репозитория ($HERE)!" >&2
        exit 1
        ;;
esac

for cmd in "${CROSS_COMPILE}gcc" make bc bison flex curl git tar xz; do
    command -v "$cmd" >/dev/null || { echo "нужна утилита хоста: $cmd" >&2; exit 1; }
done

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"

echo "[88x2bu] 1/4 загрузка и подготовка дерева Linux $KVER (modules_prepare + cfg80211 symvers)"
curl -fSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz" \
    | tar -xJ -C "$WORK"

KSRC="$WORK/linux-${KVER}"
cd "$KSRC"
touch .scmversion
mkdir -p certs
cp "$CERT_PEM" certs/sforshee.x509.pem
cp "$KCONF" .config
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" modules_prepare
KREL=$(cat include/config/kernel.release)

# Собираем net/wireless (cfg80211), чтобы получить корректный Module.symvers
# и зависимость depends: cfg80211 в итоговом 88x2bu.ko
make -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" M=net/wireless KBUILD_MODPOST_WARN=1 modules
sed "s|\t${KSRC}/|\t|" net/wireless/Module.symvers > Module.symvers

echo "[88x2bu] 2/4 клонирование и кросс-компиляция драйвера RTL8812BU ($RTL88X2BU_REPO)"
git clone --depth 1 "$RTL88X2BU_REPO" "$WORK/88x2bu-20210702"
make -j"$JOBS" \
    ARCH=arm \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KVER="$KREL" \
    KSRC="$KSRC" \
    KBUILD_MODPOST_WARN=1 \
    -C "$WORK/88x2bu-20210702" \
    modules

echo "[88x2bu] 3/4 strip, XZ (CRC32) и проверка vermagic == $KREL"
EXT_STAGE="$WORK/extstage"
make -C "$KSRC" \
    M="$WORK/88x2bu-20210702" \
    ARCH=arm \
    CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$EXT_STAGE" \
    INSTALL_MOD_STRIP=1 \
    modules_install

BUILT_KO=$(find "$EXT_STAGE" -name '88x2bu.ko*' | head -1)
[ -n "$BUILT_KO" ] || { echo "ОШИБКА: не найден собранный 88x2bu.ko*" >&2; exit 1; }

MODINFO_BIN=$(command -v modinfo || echo /sbin/modinfo)
VMAGIC=$("$MODINFO_BIN" -F vermagic "$BUILT_KO")
DEPS=$("$MODINFO_BIN" -F depends "$BUILT_KO")
case "$VMAGIC" in
    "${KREL} "*) ;;
    *) echo "ОШИБКА: несовпадение vermagic '$VMAGIC' с '$KREL'!" >&2; exit 1 ;;
esac
echo "  vermagic: $VMAGIC"
echo "  depends:  $DEPS"

echo "[88x2bu] 4/4 обновление архива модулей $MODS_TAR"
MODPACK="$WORK/modpack"
mkdir -p "$MODPACK"
tar -xJf "$MODS_TAR" -C "$MODPACK"
DEST_DIR="$MODPACK/lib/modules/$KREL/kernel/drivers/net/wireless/realtek/88x2bu"
mkdir -p "$DEST_DIR"
install -m 0644 "$BUILT_KO" "$DEST_DIR/$(basename "$BUILT_KO")"
rm -f "$MODPACK/lib/modules/$KREL/build" "$MODPACK/lib/modules/$KREL/source"

DEPMOD_BIN=$(command -v depmod || echo /sbin/depmod)
"$DEPMOD_BIN" -a -b "$MODPACK" "$KREL"
tar -C "$MODPACK" -cJf "$MODS_TAR" lib/modules
echo "[88x2bu] готово: $(ls -lh "$MODS_TAR")"
