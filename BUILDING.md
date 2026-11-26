# Сборка образа Debian 12 (Bookworm) armhf и проверка в QEMU

Сборка формирует полноценную корневую ФС **Debian 12 (Bookworm) `armhf`** с
помощью `debootstrap` и `qemu-user-static`, устанавливает пакеты через `apt-get`
в `chroot`, очищает все кэши `apt` и собирает загрузочный образ microSD.

Все тяжёлые операции (`debootstrap`, `chroot`, сборка `.img`, сжатие `.img.xz`,
временные копии для QEMU) выполняются **строго во временных ФС** (`/tmp` и
`/dev/shm`), не загрязняя каталог репозитория.

## 1. Зависимости сборочного хоста (Debian / Ubuntu x86_64)

```bash
sudo apt-get update
sudo apt-get install -y \
    debootstrap debian-archive-keyring qemu-user-static binfmt-support qemu-system-arm \
    dosfstools mtools e2fsprogs fdisk cpio xz-utils openssl kmod \
    device-tree-compiler u-boot-tools python3 gcc-arm-linux-gnueabihf libc6-dev-armhf-cross
```

* `debootstrap` + `debian-archive-keyring` + `qemu-user-static` + `binfmt-support` —
  проверка подписи репозитория Debian Bookworm (в том числе на хостах Ubuntu) и
  развёртывание `armhf` окружения Debian 12 в `chroot` через `binfmt_misc`;
* `dosfstools`, `mtools`, `e2fsprogs` — создание разделов `BOOT` (FAT16) и `rootfs` (`ext4`);
* `openssl` — проверка подписи `regulatory.db` ключом `certs/sforshee.x509.pem`;
* `qemu-system-arm` — автоматический прогон образа в эмуляторе `cubieboard`.

## 2. Быстрая сборка образа из готового ядра и U-Boot (~4–5 минут)

```bash
./scripts/build-image.sh
```

Финальные файлы создаются в `/tmp/out-debian/`:
* `/tmp/out-debian/informer701-debian.img.xz` — сжатый образ microSD (~59 МиБ, в распакованном виде 512 МиБ);
* `/tmp/out-debian/informer701-debian.sha256` — SHA-256 контрольные суммы сырого и сжатого образов.

Распакованная временная `rootfs` (`/tmp/informer701-work/rootfs`) автоматически
удаляется сразу после сборки `ext4`-раздела.

Основные переменные окружения `scripts/build-image.sh`:

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `BUILD` | Суффикс имени образа (`informer701-$BUILD.img.xz`) | `debian` |
| `WORK` | Временный рабочий каталог сборки (вне репозитория) | `/tmp/informer701-work` |
| `COPYTO` | Каталог для готового `.img.xz` и `.sha256` | `/tmp/out-debian` |
| `BOOT_DEFAULT` | Заводской пункт меню в `extlinux.conf` | `lowopp` |
| `TOTAL_MIB` | Полный объём образа microSD (степень двойки для QEMU SD) | `512` |
| `REBUILD_DEVMEM2` | `1` — перекомпилировать `prebuilt/devmem2` из `src/devmem2.c` | `0` (авто, если бинарник отсутствует) |
| `KEEP_ROOTFS` | `1` — не удалять `/tmp/informer701-work/rootfs` после сборки | `0` |

Что проверяется автоматически во время сборки:
1. Генерация и верификация всех вариантов Device Tree (`scripts/mkdtb-variants.py`).
2. Сохранность `merged-usr` симлинка `/lib -> usr/lib` и `ld-linux-armhf.so.3` при установке модулей ядра.
3. Полнота динамических библиотек `DT_NEEDED` у всех >1200 ELF-файлов (`scripts/check-libs.py`).
4. Подпись `regulatory.db.p7s` сертификатом `certs/sforshee.x509.pem` для ядра 6.6.

## 3. Автоматическое тестирование в QEMU (`scripts/qemu-test.sh`)

```bash
./scripts/qemu-test.sh
```

Скрипт создаёт разреженную копию образа в `/dev/shm`, загружает реальное ядро
`prebuilt/zImage` и **реальный `systemd` (PID 1)** в `qemu-system-arm -M cubieboard -m 512M`
и выполняет 55 автоматических проверок:
* загрузка Debian 12 Bookworm `armhf`, `glibc`, `bash`, полные репозитории `/etc/apt/sources.list` (`main contrib non-free non-free-firmware`), отсутствие упавших юнитов (`systemctl --failed`);
* монтирование `/` (`noatime`) и `/boot` (`extlinux.conf`, каталог `deb/`);
* работа сжатого swap `/dev/zram0` (`informer701-zram.service`);
* размещение `/tmp`, `/var/tmp`, `/var/log` в `tmpfs` и логов `journald` в `/run/log/journal` (RAM);
* активация аппаратного `/dev/watchdog` со стороны PID 1 `systemd` и бита `WDOG_EN` в регистре `WDOG_MODE` (`0x01c20c94`);
* работа `dropbear.service` (`:22`), `haveged.service` и политики `Restart=always`;
* сетевой стенд `usb0` (`192.168.77.1/24`) через пару `veth` и сетевой namespace: выдача адреса по DHCP (`dnsmasq` -> `dhclient`), `ping` и ответ SSH-баннера Dropbear;
* загрузка `cfg80211` + `regulatory.db`, всех ключевых Wi-Fi/USB/FS модулей, включая двухдиапазонный драйвер **`88x2bu`** (RTL8812BU/RTL8822BU, проверка совпадения `vermagic` с `uname -r`, зависимостей `cfg80211` и `/etc/modprobe.d/blacklist-rtw88.conf`), и прогон `wifi selftest`;
* работа бортовых утилит: `devmem2`, `clk`, `regs`, `info`, `whichboot`, `savelog`, `bootnext`, `usbnet`, `pkg`, `memtester`.

Лог успешного прогона сохранён в [`docs/qtest-pass.log`](docs/qtest-pass.log).

## 4. Полная пересборка с нуля (U-Boot + ядро 6.6 + 88x2bu + Debian 12)

При необходимости пересобрать загрузчик, ядро и внешний модуль `88x2bu.ko` из исходных текстов:

```bash
./scripts/build-all.sh          # качает U-Boot 2024.10, Linux 6.6 и драйвер 88x2bu в /tmp/informer701-srcbuild
./scripts/build-rtl8812bu.sh    # отдельно пересобирает только модуль 88x2bu.ko в prebuilt/modules-6.6.0-b021.tar.xz
```

Конфигурация ядра хранится в `kernel/kernel.config-b021` (включая `CONFIG_ZSMALLOC=m`,
`CONFIG_ZRAM=m`, `CONFIG_CRYPTO_LZO=m`, `CONFIG_CRYPTO_LZ4=m`, `CONFIG_SUNXI_WATCHDOG=y`).
Для перекомпиляции утилиты `prebuilt/devmem2`:

```bash
arm-linux-gnueabihf-gcc -O2 -Wall -Wextra -o prebuilt/devmem2 src/devmem2.c
```

## 5. Разметка образа microSD (512 МиБ)

| Смещение | Размер | Содержимое |
|---|---|---|
| `8 КиБ` | `~500 КиБ` | `u-boot-sunxi-with-spl.bin` (SPL + U-Boot 2024.10) |
| `1 МиБ` | `64 МиБ` | Раздел 1 (`BOOT`, FAT16): `zImage`, 12 `*.dtb`, `rescue2.cpio.gz`, `extlinux/extlinux.conf`, `deb/`, `logs/` |
| `65 МиБ` | `447 МиБ` | Раздел 2 (`rootfs`, `ext4`): Debian 12 (Bookworm) `armhf`, `systemd`, модули ядра 6.6.0, прошивки Wi-Fi и утилиты |

## 6. Автоматическая облачная сборка и релизы в GitHub Actions

Конфигурация пайплайна расположена в [`.github/workflows/build-debian.yml`](.github/workflows/build-debian.yml)
и выполняется на стандартном раннере `ubuntu-latest`.

### Сценарии запуска

1. **Автоматически при коммите в `main`**: собирается и тестируется образ с именем
   `informer701-debian12-<короткий_sha>.img.xz`.
2. **Вручную через веб-интерфейс GitHub (`workflow_dispatch`)**:
   * откройте вкладку **Actions → Build & Test Debian 12 (armhf) SD Image → Run workflow**;
   * при желании укажите свой идентификатор `BUILD` (например, `b028` или `debian12-custom`);
   * при включении опции `from_source` вместо `scripts/build-image.sh` запускается
     `scripts/build-all.sh` с полной компиляцией U-Boot 2024.10 и ядра Linux 6.6 из исходников.
3. **Публикация релиза по тегу `v*`**:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
   После успешного прохождения `qemu-test.sh` шаг `softprops/action-gh-release@v2`
   автоматически создаёт **GitHub Release** для тега `v1.0.0` и прикрепляет к нему
   `informer701-v1.0.0.img.xz` и `informer701-v1.0.0.sha256`.

### Этапы CI-пайплайна и загрузка готовых артефактов

1. Регистрация `binfmt_misc` для `arm` (`docker/setup-qemu-action@v3` + самопроверка
   прямого запуска статического `armhf` ELF-бинарника без `Exec format error`).
2. Установка сборочных пакетов (`debootstrap`, `debian-archive-keyring`, `qemu-user-static`,
   `qemu-system-arm`, `gcc-arm-linux-gnueabihf`, `dosfstools`, `mtools`, `e2fsprogs` и др.).
3. Полная сборка образа в `/tmp/out-debian/` и прогон 51 автотеста `scripts/qemu-test.sh`
   с обязательной проверкой `QTEST_RESULT: PASS`.
4. Выгрузка пакета `informer701-<BUILD>` в **GitHub Actions Artifacts** (срок хранения —
   **30 дней**): внутри архива находятся `*.img.xz`, `*.sha256` и лог `qtest-pass.log`.

