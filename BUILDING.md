# Сборка образа из этой папки

Сборка идёт **без интернета** и без платы: все бинарные артефакты, пакеты и
прошивки лежат внутри. Понадобится Linux x86-64 (проверено на Debian/Ubuntu) и
права root для `losetup`/`mkfs` (образ собирается через файловые утилиты,
реальный блочный device не нужен).

## 1. Зависимости хоста

```bash
sudo apt install bash python3 xz-utils dosfstools mtools e2fsprogs cpio \
                 openssl qemu-system-arm qemu-user-static
```

* `xz`, `dosfstools`/`mtools`, `e2fsprogs`, `cpio` — упаковка разделов образа;
* `openssl` — проверка подписи `regulatory.db` (см. `docs/regulatory-db.md`);
* `qemu-system-arm` + `qemu-user-static` — только для прогона проверок
  (`qemu-test.sh`), для самой сборки не нужны.

## 2. Сборка образа

```bash
BUILD=my1 bash scripts/build-image.sh            # результат: /tmp/out-my1/
BUILD=my1 COPYTO=$PWD bash scripts/build-image.sh  # положить .img.xz сюда же
```

Переменные окружения:

| переменная | смысл | по умолчанию |
|---|---|---|
| `BUILD` | имя сборки (имя файлов `informer701-$BUILD.img*`, метка в motd) | `b021` |
| `BOOT_DEFAULT` | пункт меню extlinux по умолчанию | `lowopp` |
| `MODULES_TGZ` | архив модулей ядра | самый свежий `prebuilt/modules-*.tar.xz` |
| `COPYTO` | куда положить `.img.xz` и `.sha256` | каталог над этой папкой |
| `TOTAL_MIB` | размер образа | `512` |

Этапы (их можно запускать и по отдельности):

1. `scripts/build-image.sh` собирает каталог артефактов `/tmp/art-$BUILD`
   (`prebuilt/zImage`, все DTB, SPL+U-Boot, rescue-initramfs, модули);
2. `scripts/prepare-rootfs.sh` готовит корень: распаковывает Alpine minirootfs
   из `pkgs/`, ставит `.apk` из `pkgs/`, кладёт прошивки из `firmware/`, модули
   ядра, утилиты из `rootfs-files/`, inittab/rcS/motd, генерирует ключи dropbear;
3. `scripts/make-sdimage.sh` размечает образ: MBR, vFAT-раздел BOOT
   (1…65 МиБ: zImage, DTB, initramfs, `extlinux/extlinux.conf`), ext4-корень;
4. архив `.img.xz` и `.sha256` кладутся в `COPYTO`. Сырой `.img` наружу не
   выдаётся — только внутрь `/tmp`.

Рядом с образом создаётся `.sha256`: **первая строка — сумма распакованного
образа** (её сверяет Rufus/balenaEtcher-пользователь после распаковки), вторая —
сумма самого `.xz`.

## 3. Проверки без платы

```bash
BUILD=my1 bash scripts/qemu-test.sh     # ~4 минуты, лог: /tmp/qtest-my1.log
```

Загружает собранный rootfs в QEMU (`cubieboard`, initramfs с тестовым `/init`)
и прогоняет несколько сотен проверок: монтирование разделов, наличие утилит и
их синтаксис, модули и прошивки, `wpa_cli`/DHCP-логика (`wifi selftest`),
подпись `regulatory.db`, регистры/масштабы АЦП AXP209, motd, i2c. Итог —
`QTEST RESULT: PASS` и число проваленных проверок.

Ограничение: у эмулятора `cubieboard` **нет хост-порта USB**, поэтому сам
WiFi-адаптер в QEMU не проверяется — только текстовая логика утилит.

Свежий лог прогона лежит в `docs/qtest-*.log`.

## 4. Пересборка ядра / DTB / U-Boot с нуля

Нужна кросс-тулчейн `arm-linux-gnueabihf` (Debian/Ubuntu) и ~10 ГиБ места:

```bash
bash kernel/prepare.sh     # ставит тулчейн, качает и распаковывает linux-6.6
bash kernel/build.sh       # sunxi_defconfig + правки scripts/config, сборка
                           # zImage и модулей, архив modules-*.tar.xz
python3 scripts/mkdtb-variants.py   # все варианты DTB из dts/ в prebuilt/
```

* конфиг ядра, на котором собран `prebuilt/zImage`: `kernel/kernel.config-b021`;
* device tree: `dts/sun4i-a10-informer-701.dts` (+ варианты в `dts/variants`);
* U-Boot: `u-boot/informer701_defconfig` (U-Boot 2024.10, sunxi);
* замечание: в v6.6 `scripts/config` принимает по одному символу за вызов —
  обёртки `en()`/`dis()` в `kernel/build.sh` это учитывают.

После пересборки ядра положите новые `zImage` и `modules-*.tar.xz` в
`prebuilt/` — `build-image.sh` подхватит их сам.

## 5. Обновление набора пакетов

`pkgs/` заполняется скриптом `scripts/fetch-apks.py` (он тянет пакет вместе с
подпакетами-библиотеками, которых нет в minirootfs: `xz-libs`, `zstd-libs`,
`libmnl` и т.п.). Список пакетов правится в начале скрипта. Без сети образ
собирается из того, что уже лежит в `pkgs/`.

## 6. Раскладка образа (512 МиБ)

| смещение | содержимое |
|---|---|
| 0 … 1 МиБ | MBR + SPL + U-Boot (`u-boot-sunxi-with-spl.bin`) |
| 1 … 65 МиБ | vFAT `boot`: `zImage`, `*.dtb`, `rescue2.cpio.gz`, `extlinux/extlinux.conf`, `uboot.env` |
| 65 МиБ … конец | ext4 `/`: Alpine 3.20, утилиты, модули, прошивки |

Меню extlinux (пункт по умолчанию — `lowopp`): наборы OPP/частот и отключений
(`safe`, `pinned`, `nofreq`, `base`, `flatvolt`, `wdt`, `nousb`, `hdmi`, …) и
`rescue` — диагностический initramfs. Переключение без интерактивного меню:
`bootnext N` (один раз), `bootnext N -p` (постоянно), `whichboot` — где мы сейчас.
