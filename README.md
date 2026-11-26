# Linux для планшета «Informer 701» (Allwinner A10) — Debian 12 (Bookworm) armhf

Готовый к прошивке набор: **полный Linux-образ Debian 12 (Bookworm) `armhf`**
(`glibc`, `bash`, `systemd`, `apt`) для SD-карты «голой» материнской платы
планшета Informer 701 (плата N708H6, SoC Allwinner A10 / `sun4i`, 512 МиБ DDR3)
плюс полный комплект скриптов и исходников для воспроизводимой сборки и
автоматической проверки в QEMU.

Плата используется без экрана, тачскрина и батарейки RTC. Распаяны и работают:
PMIC X-Powers AXP209, 512 МиБ DDR3, слот microSD, порт micro-USB (OTG),
акселерометр Freescale MMA7660 и площадка штатного Wi-Fi модуля (хост-порт
USB2 с управлением VBUS по GPIO PH3), куда подключается USB-WiFi адаптер.

## Что умеет образ

* **Базовая ОС Debian 12 (Bookworm) `armhf`**: полноценное окружение `glibc` 2.36,
  GNU `bash`, `systemd` 252, `udev`, `apt`/`dpkg`, Python 3.11.
* **Загрузка с microSD**: SPL + U-Boot 2024.10, меню `extlinux.conf` (16 профилей
  частот/питания, по умолчанию `lowopp`), ядро Linux 6.6.0 (104 модуля `.ko.xz`),
  раздел `BOOT` на FAT16 (виден с любого ПК) и корневая ФС на `ext4`.
* **Консоль и удалённый доступ**:
  * UART0 `115200 8N1` на тестпоинтах `TP20` (TX) / `TP21` (RX) с автологином
    (`serial-getty@ttyS0.service`, управление: `autologin-on` / `autologin-off`);
  * сеть и SSH по тому же кабелю micro-USB, которым питается плата:
    интерфейс `usb0` (`192.168.77.1/24`), DHCP-сервер `dnsmasq` и SSH-сервер
    `dropbear` (`ssh root@192.168.77.1`, сервис `informer701-usbnet.service`).
* **Адаптация под круглосуточную работу 24/7 и 512 МиБ ОЗУ**:
  * сжатый swap в RAM через **`zram`** (`/dev/zram0`, `lz4`/`lzo-rle`, 50% ОЗУ,
    `informer701-zram.service`, `vm.swappiness=100`);
  * защита SD-карты от износа: `/tmp`, `/var/tmp` и `/var/log` вынесены в
    `tmpfs`, `systemd-journald` настроен на `Storage=volatile` (логи в RAM),
    корень монтируется с `noatime,commit=60`, фоновые таймеры записи отключены;
  * аппаратный сторожевой таймер **`/dev/watchdog`** (`sunxi_wdt`) управляется
    напрямую PID 1 `systemd` (`RuntimeWatchdogSec=16s`), критичные службы
    (`dropbear`, `haveged`, `informer701-usbnet`, `informer701-wifi`) запущены
    с политикой `Restart=always`.
* **Wi-Fi**: поддержка USB-адаптеров (Realtek `rtl8xxxu`/`rtlwifi`, Ralink/MediaTek
  `rt2800usb`/`mt7601u`, Atheros `ath9k_htc`/`carl9170` и др.) + подписанный
  ключом `sforshee` `regulatory.db`. Утилита `wifi`: `scan`, `connect`,
  автоподключение (`informer701-wifi.service`), DHCP (`dhclient`) и статика,
  точка доступа (`wifi ap` через `hostapd` + `dnsmasq`), раздача интернета
  (`wifi share` через `iptables-legacy` NAT), лимит мощности (`wifi tx`), `wifi selftest`.
* **Пакетный менеджер (`apt`/`dpkg` + обёртка `pkg`)**: `pkg time`, `pkg update`,
  `pkg add <пакет>`, офлайн-установка `.deb` из раздела `BOOT/deb/` (`pkg local`).
* **Аппаратные утилиты**:
  * акселерометр MMA7660: `accel` (`read`, `watch`, `level`, `raw`, `info`);
  * контроллер питания AXP209: `pmic`, `pmic-regs`, `pmic-vbus` (контроль просадок 5 В);
  * низкоуровневая диагностика SoC: `devmem2`, `clk`, `regs`, `memtest`, `cftest`,
    `i2cbus`, `wdt`, `info`, `diag`, `savelog` (отчёт `diag` + `journalctl` на FAT-раздел),
    `whichboot`, `bootnext`.

## Структура репозитория

| Каталог | Содержимое |
|---|---|
| `.github/workflows/` | CI/CD пайплайн `build-debian.yml`: облачная сборка на `ubuntu-latest`, автотест в QEMU, публикация Artifacts и GitHub Releases |
| `scripts/` | Сборка rootfs (`debootstrap`), SD-образа, initramfs, проверка ELF-библиотек, автотест в QEMU |
| `rootfs-files/` | Бортовые утилиты (`usr-local-bin/`, `usr-local-sbin/`), юниты `systemd/`, конфиги `etc/` |
| `src/` | Исходный код `devmem2.c` для кросс-компиляции под `armhf` (`glibc`) |
| `prebuilt/` | Проверенные бинарные компоненты: `zImage` (6.6.0), `modules-6.6.0-b021.tar.xz` (с `zram`/`lz4`), `u-boot-sunxi-with-spl.bin`, 12 вариантов DTB, `rescue2.cpio.gz`, `devmem2` |
| `kernel/`, `dts/`, `u-boot/` | Конфиг ядра `kernel.config-b021`, исходники Device Tree, `informer701_defconfig` |
| `firmware/` | Выборка прошивок Wi-Fi из `linux-firmware` + подписанный `regulatory.db` (2023.09.01) |
| `certs/` | Сертификат `sforshee.x509.pem` для проверки подписи `regulatory.db` |
| `docs/` | Заметки по `regulatory.db` и свежий лог прохождения `qemu-test.sh` (`qtest-pass.log`) |

## Быстрый старт (прошивка SD-карты)

1. Получите готовый образ microSD одним из двух способов:
   * **Из GitHub (без локальной сборки)**: скачайте готовый проверенный образ
     `informer701-*.img.xz` со страницы **Releases** репозитория или из последнего
     успешного запуска во вкладке **Actions → Build & Test Debian 12 (armhf) SD Image → Artifacts**
     (артефакт содержит `.img.xz`, `.sha256` и лог автотестов `qtest-pass.log`).
   * **Локальная сборка**: выполните `./scripts/build-image.sh` — готовый архив появится в
     `/tmp/out-debian/informer701-debian.img.xz` (рядом файл `.sha256`).
2. Запишите образ на карту microSD (≥ 1 ГиБ, рекомендуется ≥ 4 ГиБ):
   * Linux: `xz -dc informer701-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`
   * Windows / macOS: **balenaEtcher** (пишет `.img.xz` напрямую) или **Rufus**.
3. При необходимости расширьте корневой раздел на всю карту уже на плате:
   `growpart /dev/mmcblk0 2` или `fdisk /dev/mmcblk0` + `resize2fs /dev/mmcblk0p2`.
4. Подайте питание **5 В / не менее 2 А** и подключитесь по UART0 (`115200 8N1`)
   или по SSH через кабель micro-USB: `ssh root@192.168.77.1` (пароль `informer701`).

Первые команды на плате:

```bash
info                 # сводка по ОС Debian 12, памяти, zram, watchdog и PMIC
whichboot            # активный профиль загрузки из extlinux.conf
wdt status           # состояние аппаратного watchdog (/dev/watchdog + systemd)
usbnet status        # состояние USB-сети (192.168.77.1) и SSH
wifi dev             # подключённый USB-WiFi адаптер и драйвер
wifi scan
wifi connect 'МояСеть' 'пароль'
wifi auto on         # автоподключение при старте через systemd
pkg time && pkg update && pkg add tmux
pmic-vbus            # напряжение VBUS 5 В по АЦП AXP209
accel                # показания акселерометра MMA7660 и ориентация платы
```

## Автоматическая сборка в GitHub Actions (CI/CD)

В репозитории настроен workflow [`.github/workflows/build-debian.yml`](.github/workflows/build-debian.yml),
который полностью собирает и тестирует образ на серверах GitHub (`ubuntu-latest`):

* **Автоматические триггеры**: каждый `push` в ветку `main`, создание тега вида `v*`
  (например, `v1.0.0`) и ручной запуск **Run workflow** (`workflow_dispatch` с
  опциональным `BUILD` ID и флагом полной пересборки ядра/U-Boot `from_source`).
* **Обязательный контроль качества**: каждый собранный образ загружается в
  `qemu-system-arm` с реальным `systemd` PID 1 (`scripts/qemu-test.sh`, 51 проверка);
  при любой ошибке сборка останавливается и битый образ не публикуется.
* **Скачивание артефактов**: во вкладке **Actions** выберите завершённый прогон и в
  блоке **Artifacts** скачайте архив `informer701-<BUILD>` (хранится 30 дней:
  `informer701-<BUILD>.img.xz`, `.sha256` и `qtest-pass.log`).
* **Автоматические релизы**: при отправке тега `git tag v1.0.0 && git push origin v1.0.0`
  пайплайн автоматически создаёт **GitHub Release** и прикрепляет к нему сжатый образ
  `.img.xz` и файл контрольных сумм `.sha256`.

## Сборка и тестирование локально в QEMU

Подробное описание — в [`BUILDING.md`](BUILDING.md). Коротко:

```bash
./scripts/build-image.sh    # сборка в /tmp -> /tmp/out-debian/informer701-debian.img.xz
./scripts/qemu-test.sh      # загрузка реального systemd PID 1 в QEMU (51 автотест)
```

## Железо и лицензии

* Распиновка платы, шины I2C, тестпоинты UART и USB VBUS — в [`HARDWARE.md`](HARDWARE.md).
* Сведения о лицензиях (GPL-2.0 для Linux и U-Boot, пакеты Debian 12, MIT для скриптов) — в [`LICENSES.md`](LICENSES.md).
