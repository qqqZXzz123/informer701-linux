# История изменений

| Сборка | Что добавлено / изменено |
|---|---|
| b016 | Первая рабочая связка: SPL + U-Boot 2024.10, ядро Linux 6.6, меню `extlinux.conf` с вариантами OPP, аварийный `rescue2.cpio.gz` |
| b017 | Сеть и SSH через micro-USB OTG (RNDIS/ECM-гаджет + `dropbear`): один кабель на питание, сеть и консоль |
| b018 | Проверенный на плате профиль `lowopp` (пониженная лестница частот @ 1.4 В), аппаратный watchdog во всех DTB |
| b020 | Исправлен пин VBUS хост-порта USB2: **PH3** по схеме платы N708H6 |
| b021 | Поддержка USB-WiFi (модули + прошивки + утилита `wifi`), шины I2C TWI1/TWI2 и акселерометр MMA7660 (`accel`), exFAT/NTFS, USB-Ethernet, NAT |
| b022 | `regulatory.db` заменён на выпуск `2023.09.01` с подписью `sforshee`, принимаемой ядром 6.6 |
| b025 | Диагностика питания `pmic-vbus` (АЦП AXP209, режимы `watch`/`log`/`reg`), управление мощностью передатчика `wifi tx` и энергосбережением `wifi ps` |
| b026–b027 | Улучшено ожидание инициализации USB-WiFi адаптера и добавлен автономный самотест `wifi selftest` |
| **debian12** | **Полная миграция базовой ОС с Alpine Linux 3.20 (`musl`, BusyBox `init`/`ash`, `apk`) на Debian 12 Bookworm `armhf` (`glibc` 2.36, GNU `bash`, `systemd` 252, `apt`/`dpkg`):**<br>• сборка корня через `debootstrap --arch=armhf --variant=minbase bookworm` + `qemu-user-static` строго в `/tmp` с очисткой кэшей `apt`;<br>• перевод всех 23 бортовых скриптов (`wifi`, `usbnet`, `pkg`, `accel`, `pmic*`, `wdt`, `bootnext`, `whichboot`, `diag`, `info`, `savelog` и др.) на `#!/bin/bash`, утилиты Debian (`dhclient`, `dnsmasq`, `iptables-legacy`, `ss`, `systemctl`) и `LC_NUMERIC=C`;<br>• кросс-компиляция `prebuilt/devmem2` (`src/devmem2.c`) под `armhf` `glibc`;<br>• сборка модулей ядра `zsmalloc.ko`, `zram.ko`, `lz4`/`lzo` для 6.6.0 и автонастройка сжатого swap `/dev/zram0` (50% RAM) через `informer701-zram.service`;<br>• защита SD-карты при работе 24/7: `/tmp`, `/var/tmp`, `/var/log` в `tmpfs`, `journald` `Storage=volatile` в RAM, `noatime,commit=60`;<br>• интеграция аппаратного `/dev/watchdog` (`sunxi_wdt`) с `systemd` (`RuntimeWatchdogSec=16s`) и `Restart=always` для критичных служб;<br>• обновлён стенд `scripts/qemu-test.sh` с загрузкой реального `systemd` PID 1 в QEMU (51 автоматическая проверка — 100% PASS). |
| **debian12-ci** | **Полноценный CI/CD пайплайн GitHub Actions (`.github/workflows/build-debian.yml`) и переносимость на `ubuntu-latest`:**<br>• автоматическая сборка на `push` в `main`, теги `v*` и `workflow_dispatch` (с параметрами `BUILD` и `from_source`);<br>• явная регистрация и самопроверка `binfmt_misc` (`arm`), поддержка `debian-archive-keyring` на хостах Ubuntu, авто-сборка `devmem2` при отсутствии бинарника;<br>• обязательный прогон `scripts/qemu-test.sh` (`QTEST_RESULT: PASS`) перед публикацией, выгрузка `*.img.xz`, `*.sha256` и `qtest-pass.log` в GitHub Actions Artifacts (30 дней) и автосоздание GitHub Release при отправке тегов `v*`. |

## Известные особенности

* Эмулятор QEMU (`-M cubieboard`) не эмулирует физический контроллер USB OTG (`musb`) и чипы на I2C (`AXP209`, `MMA7660`): служба `informer701-usbnet.service` штатно пропускает автостарт через `ExecCondition` при пустом `/sys/class/udc`, а сетевой стек `usb0` (`192.168.77.1`, DHCP, SSH, NAT) проверяется в QEMU на паре `veth` и сетевом namespace.
* На плате отсутствует батарейка RTC: при выходе в интернет по HTTPS сначала синхронизируйте часы командой `pkg time` (или дождитесь синхронизации `systemd-timesyncd`).
