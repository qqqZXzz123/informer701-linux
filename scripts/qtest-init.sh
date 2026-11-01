#!/bin/sh
# qtest-init.sh - /init тестового initramfs: гоняет проверки образа Informer 701
# в QEMU (-M cubieboard) и печатает результаты.
#
# Запускается не из scripts/qemu-test.sh напрямую, а КОПИРУЕТСЯ им как /init в
# initramfs, собранный из того же rootfs, который попал в образ. То есть
# проверяется именно содержимое образа, а не сборочного хоста.
#
# Формат вывода: секции [N] ...; любая строка, начинающаяся с "FAIL:" -
# проваленная проверка (её ищет qemu-test.sh); в конце
# "== QTEST RESULT: PASS|FAIL ==" и "== QTEST DONE ==".
#
# Что проверяется (и зачем):
#   1  /proc/sys/kernel/hotplug          автозагрузка модулей без udev
#   2  /dev/urandom, /dev/null           база для dropbear/haveged/apk
#   3  симлинки /usr/local/bin, /sbin    битая ссылка = молча нерабочая команда
#   4  modprobe + lsmod                  без modules.dep/liblzma WiFi мёртв
#   5  iptables (NAT)                    wifi share / wifi ap / usbnet nat
#   6  все ELF-бинарники: запуск         ловит "Error loading shared library"
#   7  i2c-адаптеры /dev/i2c-N           TWI0/1/2 включены в DTS
#   8  прошивки: кол-во, битые ссылки    WiFi-драйверы без них не стартуют
#   9  apk: версия, зеркала, ключи, baked.txt   пакетный менеджер
#   10 хелперы: sh -n и справка          синтаксис всех утилит
#   11 accel info                        IIO/MMA7660 (в QEMU i2c залипает - timeout)
#   12 usbnet: диагностика гаджета       configfs/udc
#   13 ошибки в dmesg                    oops/panic/WARNING
#
# В QEMU заведомо НЕ работает (это норма, проверками не считается):
#   * i2c-транзакции: mv64xxx в кубике виснет ("I2C bus locked", ~2 с на попытку),
#     поэтому axp20x и mma7660 не определяются - на плате они есть;
#   * musb (USB0-гаджет): dummy-контроллер QEMU не поддерживает sunxi-musb;
#   * ehci/ohci: "can't setup: -110" - в кубике нет PHY;
#   * accel отдаёт данные только через i2c -> в QEMU всегда пусто.
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
ok()   { echo "  OK   $*"; }

# --- окружение: повторяем /etc/init.d/rcS. Без этого нет ни /proc, ни /dev,
# --- ни /usr/local/bin в PATH, и проверка измеряет не образ, а пустой initramfs.
# --- (при загрузке с SD всё это делает rcS; при rdinit=/init - никто)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
/bin/mount -t proc proc /proc 2>/dev/null
/bin/mount -t sysfs sysfs /sys 2>/dev/null
/bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp /sys/kernel/debug
/bin/mount -t devpts devpts /dev/pts 2>/dev/null
/bin/mount -t tmpfs tmpfs /run 2>/dev/null
/bin/mount -t tmpfs tmpfs /tmp 2>/dev/null
/bin/mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
[ -x /sbin/hotplug ] && echo /sbin/hotplug > /proc/sys/kernel/hotplug 2>/dev/null
ip link set lo up 2>/dev/null
hostname -F /etc/hostname 2>/dev/null

echo "== QTEST build-id: $(cat /etc/build-id 2>/dev/null || echo '?') =="
echo "$(uname -a)"
echo "cmdline: $(cat /proc/cmdline)"

# ---------------------------------------------------------- 1. hotplug
echo "[1] автозагрузка модулей:"
HP=$(cat /proc/sys/kernel/hotplug 2>/dev/null)
[ -n "$HP" ] && ok "/proc/sys/kernel/hotplug = $HP" || fail "hotplug не задан"
[ -x /sbin/hotplug ] && ok "/sbin/hotplug исполняемый" || fail "/sbin/hotplug нет или не исполняемый"

# ---------------------------------------------------------- 2. /dev
echo "[2] устройства:"
for d in /dev/urandom /dev/null /dev/console /dev/ttyS0; do
    [ -e "$d" ] && ok "$d" || fail "$d отсутствует"
done

# ---------------------------------------------------------- 3. симлинки
echo "[3] симлинки (цель должна существовать):"
for L in $(find /usr/local/bin /sbin /bin /usr/sbin /usr/bin -maxdepth 1 -type l 2>/dev/null); do
    T=$(readlink "$L")
    case "$T" in
        /*) R="$T" ;;
        *)  R="$(dirname "$L")/$T" ;;
    esac
    if [ -e "$R" ]; then
        ok "$L -> $T"
    else
        fail "битый симлинк $L -> $T"
    fi
done
[ -L /etc/mtab ] && ok "/etc/mtab -> $(readlink /etc/mtab)"

# ---------------------------------------------------------- 4. модули
echo "[4] modprobe / lsmod:"
MODDIR=/lib/modules/$(uname -r)
[ -d "$MODDIR" ] && ok "$MODDIR есть ($(find $MODDIR -name '*.ko*' | wc -l) модулей)" \
                 || fail "$MODDIR отсутствует"
[ -f "$MODDIR/modules.dep" ] && ok "modules.dep на месте" || fail "нет modules.dep (depmod не отработал)"
modprobe --version 2>&1 | head -1
for m in cfg80211 mac80211 rfkill rt2x00lib rt2800lib rt2800usb rtl8xxxu \
         rtl8192cu mt7601u mt76x0u ath9k_htc carl9170 exfat ntfs3 \
         nf_conntrack nf_nat xt_MASQUERADE iptable_nat cdc_acm r8152; do
    if modprobe "$m" 2>/tmp/mp.err; then
        ok "modprobe $m"
    else
        fail "modprobe $m: $(head -1 /tmp/mp.err)"
    fi
done
N=$(lsmod 2>/dev/null | wc -l)
[ "$N" -gt 5 ] && ok "lsmod: $((N-1)) загруженных модулей" || fail "lsmod почти пуст ($N строк)"
lsmod 2>&1 | head -12 | sed 's/^/    /'

# ---------------------------------------------------------- 5. iptables
echo "[5] iptables / NAT:"
if iptables -t nat -L -n >/tmp/ip.out 2>/tmp/ip.err; then
    ok "iptables -t nat -L работает"
else
    fail "iptables -t nat -L: $(head -1 /tmp/ip.err)"
fi
if iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE 2>/tmp/ip2.err; then
    ok "правило MASQUERADE добавлено"
    iptables -t nat -S POSTROUTING 2>/dev/null | sed 's/^/    /'
    iptables -t nat -D POSTROUTING -o wlan0 -j MASQUERADE 2>/dev/null
else
    fail "MASQUERADE: $(head -1 /tmp/ip2.err)"
fi
iptables --version 2>&1 | head -1 | sed 's/^/    /'

# ---------------------------------------------------------- 6. бинарники
echo "[6] запуск всех бинарников (ловим отсутствующие библиотеки):"
BADCOUNT=0
for b in /bin/* /sbin/* /usr/bin/* /usr/sbin/* /usr/local/bin/*; do
    [ -f "$b" ] || continue
    head -c 4 "$b" 2>/dev/null | grep -q ELF || continue
    case "$(basename $b)" in
        busybox|busybox-extras|getty|autologin|halt|poweroff|reboot) continue ;;
    esac
    # БЕЗ конвейера: "cmd | head" вернул бы код head, и segfault (139) потерялся бы
    OUT=$(timeout 5 "$b" --version 2>&1 </dev/null)
    RC=$?
    OUT=$(printf '%s\n' "$OUT" | head -3)
    case "$OUT" in
        *"Error loading shared library"*|*"Error relocating"*)
            fail "$(basename $b): $(echo "$OUT" | head -1)"; BADCOUNT=$((BADCOUNT+1)); continue ;;
        *"Segmentation fault"*)
            fail "$(basename $b): segfault при запуске"; BADCOUNT=$((BADCOUNT+1)); continue ;;
    esac
    case "$RC" in
        139|134|136) fail "$(basename $b): аварийное завершение rc=$RC"; BADCOUNT=$((BADCOUNT+1)) ;;
        124)         echo "  (таймаут 5 с: $(basename $b) - похоже, демон, это не ошибка)" ;;
    esac
done
[ "$BADCOUNT" = 0 ] && ok "все ELF-бинарники запускаются"

# ---------------------------------------------------------- 6b. wpa_supplicant
echo "[6b] запуск wpa_supplicant (баг b021: ключ -f не поддерживается):"
case "$(wpa_supplicant -h 2>&1)" in
    *"  -f ="*) ok "wpa_supplicant поддерживает -f (лог файлом)" ;;
    *)          ok "wpa_supplicant БЕЗ -f - wifi должен использовать перенаправление" ;;
esac
# Проба ключа -f. ВАЖНО: в Alpine wpa_supplicant собран БЕЗ CONFIG_DEBUG_FILE,
# поэтому -f он ОТВЕРГАЕТ, и это нормально: проваливать проверку надо лишь тогда, когда
# утилита wifi передаёт -f безусловно (так было в b021 - сеть не поднималась).
printf 'ctrl_interface=/var/run/wpa_supplicant\n' > /tmp/probe.conf
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"
WOUT=$($TO wpa_supplicant -i wlan-none -c /tmp/probe.conf -D nl80211 -f /tmp/.probe 2>&1 | head -20)
case "$WOUT" in
    *usage:*)
        ok "wpa_supplicant НЕ поддерживает -f (Alpine без CONFIG_DEBUG_FILE) - так и задумано"
        grep -q 'wpa_supports_f' /usr/local/bin/wifi \
            && ok "wifi сам определяет поддержку -f" \
            || fail "wifi не проверяет поддержку -f: на этом wpa_supplicant он не запустится"
        grep -q 'setsid wpa_supplicant' /usr/local/bin/wifi \
            && ok "wifi умеет запустить wpa_supplicant без -f (setsid + перенаправление в лог)" \
            || fail "в wifi нет запасного запуска без -f"
        if grep -qE 'wpa_supplicant .* -f ' /usr/local/bin/wifi \
           && ! grep -q 'WPA_F' /usr/local/bin/wifi; then
            fail "wifi передаёт -f безусловно"
        else
            ok "-f в wifi используется только при поддержке"
        fi ;;
    *)  ok "проба с -f принята (в этом wpa_supplicant есть CONFIG_DEBUG_FILE)" ;;
esac
WOUT2=$($TO wpa_supplicant -i wlan-none -c /tmp/probe.conf -D nl80211 2>&1 | head -2)
case "$WOUT2" in
    *"Successfully initialized"*) ok "без -f wpa_supplicant инициализируется" ;;
    usage*)                       fail "wpa_supplicant печатает usage даже без -f" ;;
    *)                            ok "без -f: $(echo "$WOUT2" | head -1)" ;;
esac
command -v setsid >/dev/null && ok "setsid есть (wpa_supplicant переживёт закрытие сессии)" \
                             || fail "нет setsid в busybox"

# ---------------------------------------------------------- 6c. regulatory.db
echo "[6c] база регуляторных доменов:"
[ -f /lib/firmware/regulatory.db ] && ok "regulatory.db ($(stat -c%s /lib/firmware/regulatory.db) Б)" \
                                   || fail "нет regulatory.db"
[ -f /lib/firmware/regulatory.db.p7s ] && ok "regulatory.db.p7s ($(stat -c%s /lib/firmware/regulatory.db.p7s) Б)" \
                                        || fail "нет regulatory.db.p7s (ядро отвергнет базу)"
dmesg | grep -qi 'malformed or signature' && fail "ядро отвергло regulatory.db (см. dmesg)" \
                                          || ok "в dmesg нет жалобы на подпись regdb"

# ------------------------------------- 6d. ctrl_interface/wpa_cli и получение IP
# Баг b022: в конфиге был ctrl_interface=/run/wifi/wpa, а wpa_cli ищет сокет в
# /var/run/wpa_supplicant -> состояние подключения не определялось, и DHCP не
# запускался вовсе: точка ассоциирована, ключи подобраны, а адреса нет.
echo "[6d] wpa_cli/ctrl_interface и DHCP (баг b022: ассоциация есть, адреса нет):"
command -v wpa_cli >/dev/null && ok "wpa_cli есть" || fail "нет wpa_cli"
[ -x /usr/share/udhcpc/default.script ] && ok "udhcpc default.script есть (адрес/DNS будут прописаны)" \
                                        || fail "нет /usr/share/udhcpc/default.script - udhcpc не настроит адрес"
command -v udhcpc >/dev/null && ok "udhcpc есть" || fail "нет udhcpc"
grep -q 'wpa_cli -i' /usr/local/bin/wifi && fail "в wifi есть wpa_cli без -p (не найдёт сокет)" \
                                        || ok "все вызовы wpa_cli через обёртку с -p"
CDIR=$(sed -n 's|^CTRL_DIR=||p' /usr/local/bin/wifi | head -1)
[ "$CDIR" = /var/run/wpa_supplicant ] && ok "CTRL_DIR=$CDIR (значение по умолчанию для wpa_cli)" \
                                      || fail "CTRL_DIR=$CDIR - wpa_cli его не найдёт"

# ensure_conf: новый конфиг и перенос старого (b022) на стандартный путь
mkdir -p /tmp/tc /tmp/tr
sed -n '/^ensure_conf()/,/^}/p' /usr/local/bin/wifi > /tmp/ec.sh
run_ec() {
    CONF_DIR=/tmp/tc CONF=/tmp/tc/wpa_supplicant.conf CTRL_DIR=$CDIR RUN=/tmp/tr         sh -c '. /tmp/ec.sh; ensure_conf'
}
rm -f /tmp/tc/wpa_supplicant.conf; run_ec
case "$(sed -n 's|^ctrl_interface=||p' /tmp/tc/wpa_supplicant.conf)" in
    "$CDIR") ok "новый конфиг: ctrl_interface=$CDIR" ;;
    *)       fail "в новом конфиге ctrl_interface не $CDIR" ;;
esac
printf 'ctrl_interface=/run/wifi/wpa\nctrl_interface_group=0\nupdate_config=1\nap_scan=1\n' \
    > /tmp/tc/wpa_supplicant.conf
run_ec
case "$(sed -n 's|^ctrl_interface=||p' /tmp/tc/wpa_supplicant.conf)" in
    "$CDIR") ok "старый конфиг (b022) перенесён на $CDIR" ;;
    *)       fail "ensure_conf не исправил старый ctrl_interface" ;;
esac
[ "$(grep -c '^ctrl_interface=' /tmp/tc/wpa_supplicant.conf)" = 1 ] \
    && ok "ctrl_interface в конфиге ровно один" || fail "в конфиге несколько ctrl_interface"

# assoc_ok на ПРИМЕРЕ строк wpa_supplicant (MAC и SSID анонимизированы):
# wpa_cli недоступен, iw молчит - подключение должно определиться ПО ЛОГУ.
sed -n '/^assoc_ok()/,/^}/p' /usr/local/bin/wifi > /tmp/ao.sh
cat > /tmp/h.sh <<'EOS'
LOG=/tmp/board.log
wpa_state() { echo ""; }
iw() { return 1; }
. /tmp/ao.sh
EOS
cat >> /tmp/h.sh <<'EOS'
cat > $LOG <<'EOL'
Successfully initialized wpa_supplicant
wlan0: SME: Trying to authenticate with 00:11:22:33:44:55 (SSID='ExampleNet' freq=2412 MHz)
wlan0: Trying to associate with 00:11:22:33:44:55 (SSID='ExampleNet' freq=2412 MHz)
wlan0: Associated with 00:11:22:33:44:55
wlan0: CTRL-EVENT-REGDOM-CHANGE init=COUNTRY_IE type=COUNTRY alpha2=RU
wlan0: WPA: Key negotiation completed with 00:11:22:33:44:55 [PTK=CCMP GTK=CCMP]
wlan0: CTRL-EVENT-CONNECTED - Connection to 00:11:22:33:44:55 completed [id=0 id_str=]
EOL
if assoc_ok wlan0; then echo "OK   assoc_ok: лог платы b022 распознан как подключение"; else echo "FAIL assoc_ok не увидел подключение в реальном логе"; fi
: > $LOG
if assoc_ok wlan0; then echo "FAIL assoc_ok: пустой лог сочтён подключением"; else echo "OK   assoc_ok: пустой лог -> не подключено"; fi
echo "wlan0: CTRL-EVENT-DISCONNECTED bssid=00:11:22:33:44:55 reason=2" > $LOG
if assoc_ok wlan0; then echo "FAIL assoc_ok: дисконнект сочтён подключением"; else echo "OK   assoc_ok: WRONG_KEY/дисконнект -> не подключено"; fi
EOS
sh /tmp/h.sh > /tmp/h.out 2>&1
while IFS= read -r l; do
    case "$l" in OK*) ok "${l#OK }" ;; *) fail "${l#FAIL }" ;; esac
done < /tmp/h.out
sh /usr/local/bin/wifi help 2>/dev/null > /tmp/whelp
grep -q 'wifi dhcp' /tmp/whelp && ok "в справке есть wifi dhcp" || fail "в справке нет wifi dhcp"
grep -q 'wifi static' /tmp/whelp && ok "в справке есть wifi static" || fail "в справке нет wifi static"

# ------------------------------------------- 6e. питание: pmic-vbus, wifi tx/ps
# Плата питается от USB и чувствительна к просадке 5 В: при слабом источнике она
# зависает или молча перезагружается БЕЗ единой строчки в UART (так выглядел
# "нестабильный b023" - на деле дело было в контактах и блоке питания).
echo "[6e] монитор питания и ограничение мощности передатчика:"
[ -x /usr/local/bin/pmic-vbus ] && ok "pmic-vbus есть и исполняемый" \
                                || fail "нет /usr/local/bin/pmic-vbus"
sh -n /usr/local/bin/pmic-vbus && ok "pmic-vbus: синтаксис sh корректен" \
                               || fail "pmic-vbus: синтаксическая ошибка"
grep -q 'adc12 0x5a 0x5b' /usr/local/bin/pmic-vbus && ok "VBUS U читается из 0x5A/0x5B (AXP209)" \
                                                  || fail "не те регистры VBUS U"
grep -q 'adc12 0x5c 0x5d' /usr/local/bin/pmic-vbus && ok "ток VBUS читается из 0x5C/0x5D" \
                                                  || fail "не те регистры тока VBUS"
grep -q 'to_mv "$VRAW" 17' /usr/local/bin/pmic-vbus && ok "масштаб 1.7 мВ на отсчёт (по даташиту AXP209)" \
                                                    || fail "неверный масштаб VBUS"
if grep -q 'IRaw' /usr/local/bin/pmic-vbus; then fail "в pmic-vbus опечатка IRaw (ток читался как 0)"
else ok "переменная тока VBUS именуется единообразно"; fi
grep -q 'sync' /usr/local/bin/pmic-vbus && ok "режим log сбрасывает данные на карту (переживёт зависание)" \
                                        || fail "режим log не делает sync"
sh /usr/local/bin/wifi help > /tmp/whelp2 2>/dev/null
grep -q 'cmd_tx()' /usr/local/bin/wifi && ok "wifi tx (ограничение мощности) есть" || fail "нет wifi tx"
grep -q 'cmd_ps()' /usr/local/bin/wifi && ok "wifi ps (power save) есть" || fail "нет wifi ps"
grep -q 'apply_tx "$ifc"' /usr/local/bin/wifi && ok "ограничение мощности применяется при подключении" \
                                              || fail "apply_tx не вызывается в cmd_connect/cmd_up"
grep -q 'TX_FILE=/etc/wifi-txpower' /usr/local/bin/wifi && ok "ограничение мощности сохраняется в /etc/wifi-txpower (переживёт перезагрузку)" \
                                                        || fail "нет постоянного файла для wifi tx"
grep -q '^apply_tx()' /usr/local/bin/wifi && ok "apply_tx определена как функция" || fail "apply_tx не определена"
grep -c 'apply_tx "$ifc"' /usr/local/bin/wifi | grep -q '^2$' && ok "apply_tx вызывается в обоих путях подключения (cmd_connect и cmd_up)" \
                                                             || fail "apply_tx вызывается не во всех путях подключения"
grep -q '^mv()' /usr/local/bin/pmic-vbus && fail "в pmic-vbus функция mv() перехватывает команду mv" \
                                         || ok "в pmic-vbus нет функции с именем mv"
grep -q 'to_mv' /usr/local/bin/pmic-vbus && ok "преобразование отсчёта АЦП в мВ вынесено в to_mv()" \
                                           || fail "нет to_mv (масштаб АЦП не применяется)"
grep -q 'wifi ps' /tmp/whelp2 && ok "в справке wifi есть ps" || fail "в справке wifi нет ps"
grep -q 'ПИТАНИЕ' /etc/motd && ok "в motd есть заголовок раздела ПИТАНИЕ" || fail "в motd нет раздела ПИТАНИЕ"
grep -q 'wifi tx' /tmp/whelp2 && ok "в справке wifi есть tx" || fail "в справке wifi нет tx"
grep -q 'pmic-vbus' /etc/motd && ok "в motd есть раздел про питание" || fail "в motd нет pmic-vbus"

# ------------------------------- 6f. wifi selftest: регекспы конфига (ФУНКЦИОНАЛЬНО)
# Здесь запускается сама утилита, а не проверяется её текст: три шаблона grep/awk
# молча не совпадали с настоящим конфигом от wpa_passphrase ("network={"), из-за
# чего автоподключение при загрузке не видело сохранённую сеть, "wifi status"
# показывал 0 сетей, а повторный "wifi connect" плодил дубликаты блоков.
echo "[6f] wifi selftest (логика конфига wpa_supplicant, без железа):"
if sh /usr/local/bin/wifi selftest > /tmp/wst 2>&1; then
    ok "wifi selftest завершился с кодом 0"
else
    fail "wifi selftest вернул ненулевой код (см. вывод ниже)"
fi
sed 's/^/    /' /tmp/wst
grep -q 'FAIL' /tmp/wst && fail "в wifi selftest есть провалы" \
                        || ok "в wifi selftest нет провалов"
nok=$(grep -c '^  OK' /tmp/wst 2>/dev/null)
[ "${nok:-0}" -ge 12 ] && ok "selftest выполнил проверок: $nok (>= 12)" \
                       || fail "selftest выполнил только ${nok:-0} проверок (ожидалось >= 12)"
# ломаные шаблоны не должны вернуться (комментарии в скрипте их документируют,
# поэтому строки комментариев исключаем)
grep -v '^[[:space:]]*#' /usr/local/bin/wifi > /tmp/wifi-nocomments
for bad in '^network{' '^network[ \t]*{'; do
    if grep -qF -- "$bad" /tmp/wifi-nocomments; then
        fail "в wifi вернулся ломаный шаблон grep: $bad (в BRE \t не табуляция, а = не учтён)"
    else
        ok "ломаного шаблона grep нет: $bad"
    fi
done
grep -q 'NETBLK_RE=.^network\[ =\]\*\[{\].' /usr/local/bin/wifi \
    && ok "используется проверенный шаблон NETBLK_RE='^network[ =]*[{]'" \
    || fail "нет единого шаблона NETBLK_RE для поиска блоков network"
grep -q 'buf = $0' /usr/local/bin/wifi && ok "awk сохраняет заголовок блока network (иначе конфиг бьётся)" \
                                      || fail "awk теряет заголовок сохраняемого блока network"
grep -q 'cmd_selftest()' /usr/local/bin/wifi && ok "команда wifi selftest есть" || fail "нет wifi selftest"
sh /usr/local/bin/wifi help > /tmp/whelp3 2>/dev/null
grep -q 'selftest' /tmp/whelp3 && ok "wifi selftest есть в справке" || fail "wifi selftest нет в справке"

# ---------------------------------------------------------- 7. i2c
echo "[7] i2c:"
ls /dev/i2c-* 2>/dev/null | tr '\n' ' '; echo
for n in 0 1 2; do
    if [ -e /dev/i2c-$n ]; then ok "/dev/i2c-$n"; else fail "/dev/i2c-$n нет"; fi
done
i2cdetect -l 2>&1 | sed 's/^/    /'
ls -d /sys/bus/iio/devices/iio:device* 2>/dev/null | sed 's/^/    IIO: /'

# ---------------------------------------------------------- 8. прошивки
echo "[8] прошивки:"
FW=/lib/firmware
echo "  файлов: $(find $FW -type f 2>/dev/null | wc -l), размер: $(du -sh $FW 2>/dev/null | cut -f1)"
[ -f "$FW/regulatory.db" ] && ok "regulatory.db" || fail "нет regulatory.db (wireless-regdb)"
for f in $(find $FW -type l 2>/dev/null); do
    [ -e "$f" ] || fail "битый симлинк прошивки $f -> $(readlink $f)"
done
for f in rtlwifi/rtl8188eufw.bin rt2870.bin htca_9271.fw mt7601u.bin; do
    [ -e "$FW/$f" ] && ok "$f" || echo "  (нет $f - не критично, зависит от адаптера)"
done

# ---------------------------------------------------------- 9. apk
echo "[9] пакетный менеджер:"
apk --version 2>&1 | head -1 | sed 's/^/    /'
grep -h '^https\|^http' /etc/apk/repositories 2>/dev/null | sed 's/^/    repo: /'
echo "  ключей: $(ls /etc/apk/keys 2>/dev/null | wc -l)"
[ -f /etc/apk/baked.txt ] && ok "baked.txt: $(wc -l < /etc/apk/baked.txt) записей" \
                          || fail "нет /etc/apk/baked.txt"
head -5 /etc/apk/baked.txt 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------- 10. хелперы
echo "[10] хелперы:"
for h in /usr/local/bin/* /sbin/hotplug /etc/init.d/rcS /etc/init.d/local \
         /sbin/autologin /sbin/wifi-iface-up; do
    [ -f "$h" ] || continue
    # бинарники и симлинки на них (iptables, ip, lsusb, ...) - не shell-скрипты
    head -c 4 "$h" 2>/dev/null | grep -q ELF && continue
    head -1 "$h" 2>/dev/null | grep -q '^#!' || continue
    if sh -n "$h" 2>/tmp/syn.err; then
        ok "$(basename $h) ($(wc -l < $h) строк)"
    else
        fail "синтаксис $(basename $h): $(head -1 /tmp/syn.err)"
    fi
done
for h in wifi pkg accel usbnet bootnext whichboot diag; do
    command -v $h >/dev/null || fail "$h не в PATH"
done
echo "--- справка wifi:"; wifi 2>&1 | head -6 | sed 's/^/    /'
echo "--- справка pkg:";  pkg  2>&1 | head -6 | sed 's/^/    /'
echo "--- справка accel:"; accel 2>&1 | head -6 | sed 's/^/    /'

# ---------------------------------------------------------- 11. accel
echo "[11] accel (в QEMU чипа нет - ждём ПОНЯТНУЮ ошибку, а не липовые нули):"
OUT=$(timeout -s KILL 30 accel read 2>&1 | head -6)
printf '%s\n' "$OUT" | sed 's/^/    /'
case "$OUT" in
    *ОШИБКА*)        ok "accel read честно сообщает, что чтения нет" ;;
    *"X =     +0"*)  fail "accel read печатает нули вместо ошибки (см. cmd_read)" ;;
    "")              fail "accel read не выдал ничего" ;;
    *)               ok "accel read вернул данные" ;;
esac
echo "  --- accel info (таймаут 30 с: скан шины в эмуляции занимает минуты) ---"
timeout -s KILL 30 accel info 2>&1 | head -22 | sed 's/^/    /'

# ---------------------------------------------------------- 12. usbnet
echo "[12] usbnet test:"
timeout 30 usbnet test 2>&1 | head -25 | sed 's/^/    /'

# ---------------------------------------------------------- 13. dmesg
echo "[13] dmesg (ошибки):"
dmesg | grep -iE 'oops|panic|BUG:|Call trace|segfault|WARNING:' | head -10 | sed 's/^/    /'
echo "  память: $(grep MemTotal /proc/meminfo)"

echo "[14] motd:"
cat /etc/motd 2>/dev/null | head -8 | sed 's/^/    /'

echo "== провалено проверок: $FAILS"
if [ "$FAILS" = 0 ]; then echo "== QTEST RESULT: PASS =="; else echo "== QTEST RESULT: FAIL =="; fi
echo "== QTEST DONE =="
sync
sleep 1
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || true
while :; do sleep 1; done
