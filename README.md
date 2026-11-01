# Linux для планшета «Informer 701» (Allwinner A10)

Готовый к прошивке набор: **полный Linux-образ для SD-карты** bare-платы
планшета Informer 701 (основная плата N708H6, SoC Allwinner A10 / sun4i)
плюс **всё, что нужно, чтобы собрать такой образ заново** из этой папки.

Плата — «голая»: без экрана, тачскрина и батареи RTC. Из штатного осталось
то, что распаяно: PMIC AXP209, DDR3 512 МиБ, SD-слот, micro-USB (OTG),
акселерометр MMA7660 и площадка бывшего WiFi-модуля, которая на этой плате
является хост-портом USB2 — в неё и вставляется USB-WiFi адаптер.

## Что умеет образ

* Загрузка с SD-карты: SPL + U-Boot 2024.10, меню extlinux, ядро Linux 6.6
  (97 модулей), корень на ext4, раздел BOOT на vFAT (видно из Windows).
* Консоль: UART 115200 (тестпоинты TP20/TP21) **или** SSH/сеть через тот же
  micro-USB-кабель, которым плата питается (`ssh root@192.168.77.1`).
* WiFi: любой USB-адаптер, который поддерживает включённый драйвер
  (проверено: Realtek RTL8188FU, `rtl8xxxu`). Утилита `wifi`: scan, connect
  с запоминанием сети, автоподключение при загрузке, DHCP/статика, режим точки
  доступа (`wifi ap`), раздача интернета на ПК (`wifi share`), ограничение
  мощности передатчика (`wifi tx`).
* Пакетный менеджер Alpine 3.20 (armv7): `pkg update`, `pkg add <имя>`,
  установка локальных `.apk` без интернета (`pkg local`).
* Акселерометр MMA7660: `accel` (X/Y/Z в м/с², какая сторона вверх).
* Диагностика железа: `pmic` / `pmic-regs` / `pmic-vbus` (регистры и АЦП AXP209,
  в том числе напряжение питания), `clk`, `regs`, `memtest`, `cftest`, `i2cbus`,
  `info`, `diag`, `savelog` (сохранить лог на vFAT-раздел, видимый из Windows).
* Питание и зависания: аппаратный watchdog включён, `reboot`/`poweroff`
  работают сами; `bootnext N` — перезагрузиться в пункт N меню один раз или
  постоянно (`-p`), без интерактивного меню U-Boot.
* Файловые системы: exFAT/NTFS (флешки в USB-разъёме, русские имена читаются),
  ~25 драйверов USB-Ethernet, netfilter/NAT.

## Что в папке

| каталог | содержимое |
|---|---|
| `scripts/` | сборка образа, rootfs, SD-разметки, initramfs, QEMU-тест |
| `rootfs-files/` | утилиты платы (`wifi`, `pkg`, `usbnet`, `accel`, `pmic-vbus`, …), inittab, rcS, motd |
| `prebuilt/` | проверенные бинарные артефакты: `zImage`, модули ядра, SPL+U-Boot, DTB, rescue-initramfs |
| `kernel/`, `dts/`, `u-boot/` | конфиг ядра, исходники device tree, defconfig U-Boot (для пересборки с нуля) |
| `pkgs/` | Alpine minirootfs 3.20.9 armv7 + набор `.apk` (сборка работает без интернета) |
| `firmware/` | прошивки WiFi из linux-firmware + подписанный `regulatory.db` |
| `certs/` | открытый ключ sforshee для проверки подписи `regulatory.db` |
| `docs/` | ограничения regulatory.db, лог последнего прогона QEMU-теста |

## Быстрый старт (прошивка)

1. Скачайте или соберите образ (см. ниже). Файл образа — `informer701-*.img.xz`
   (512 МиБ в распакованном виде).
2. Запишите на SD-карту ≥ 4 ГиБ:
   * balenaEtcher пишет `.img.xz` напрямую;
   * Rufus — распакованный `.img`;
   * Linux: `xzcat informer701-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`.
3. Сверьте контрольную сумму (файл `.sha256` рядом с образом; первая строка —
   сумма распакованного образа).
4. Вставьте карту, подайте питание **5 В / не менее 2 А** (плата чувствительна
   к просадкам: слабый источник даёт молчаливые перезагрузки без сообщений),
   подключите UART или micro-USB.
5. Вход: `root`, пароль `informer701`. **Смените пароль** (`passwd`) и хост-ключи
   dropbear (`/etc/dropbear/`) перед использованием в своей сети.

Первые команды на плате:

```sh
whichboot            # каким пунктом меню загружена плата
usbnet status        # сеть/SSH через micro-USB
wifi dev             # виден ли WiFi-адаптер и какой драйвер
wifi scan
wifi connect 'МояСеть' 'пароль'
wifi auto on         # подключаться при каждой загрузке
pkg time && pkg update && pkg add htop    # время обязательно: батарейки RTC нет
pmic-vbus            # напряжение питания по АЦП AXP209
accel                # акселерометр
```

## Сборка образа из этой папки

Подробно — в [`BUILDING.md`](BUILDING.md). Коротко:

```bash
sudo apt install xz-utils dosfstools mtools e2fsprogs cpio python3 \
     qemu-system-arm qemu-user-static          # зависимости хоста
BUILD=my1 bash scripts/build-image.sh         # образ: /tmp/out-my1 + копия рядом
BUILD=my1 bash scripts/qemu-test.sh           # прогон проверок без платы
```

Сборка не требует интернета: minirootfs, пакеты, прошивки и подписанный
`regulatory.db` лежат в `pkgs/` и `firmware/`.

## Железо, пины и адреса

См. [`HARDWARE.md`](HARDWARE.md): UART на TP20/TP21, WiFi-разъём = USB2 с
управлением VBUS через PH3, AXP209 на TWI0 (0x34), MMA7660 на TWI1 (0x4c),
разметка SD-карты и пункты меню загрузки.

## Лицензии

Ядро Linux и U-Boot — GPL-2.0; вместе с бинарными артефактами в `prebuilt/`
здесь лежат конфиг ядра, device tree и defconfig — этого достаточно для
пересборки. Пакеты Alpine и прошивки linux-firmware распространяются на своих
условиях (см. [`LICENSES.md`](LICENSES.md)). Собственные скрипты и документы
этой папки — MIT.

Проект не связан с производителем планшета и предоставляется «как есть».
