# Прошивки WiFi для Informer 701 (b021+)

Каталог копируется в образ целиком (`prepare-rootfs.sh`) как `/lib/firmware`.
Все симлинки **разыменованы** (`cp -L`) — в linux-firmware часть файлов это
ссылки (`mt7601u.bin -> mediatek/mt7601u.bin`), а целей в выборке нет.

Состав: выборка из linux-firmware (Alpine `linux-firmware-*`) ровно под
драйверы, собранные в ядре b021 — rtlwifi/*, rt2870.bin, rt73.bin, mt7601u.bin,
mediatek/mt76*, htc_9271/7010.fw, ath9k_htc/*, ath6k/AR6004/*, carl9170-1.fw,
vntwusb.fw, mrvl/usb8*, rsi/rs9113*/rs9116*, brcm/brcmfmac4323*+43242*,
regulatory.db(.p7s).

## regulatory.db — ПОЧЕМУ ВЕРСИЯ 2023.09.01, А НЕ САМАЯ НОВАЯ

Ядро 6.6 проверяет подпись базы регуляторных доменов по сертификату,
вшитому в само ядро: `net/wireless/certs/sforshee.hex` (только ключ
**Seth Forshee**, `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` +
`CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y`).

С выпуска wireless-regdb **2024.01.23** базу подписывает **Chen-Yu Tsai (wens)**,
и такой подписи ядро 6.6 не знает. Именно поэтому в b021 (взят пакет Alpine
`wireless-regdb 2024.05.08`) в dmesg было:

```
cfg80211: Loading compiled-in X.509 certificates for regulatory database
cfg80211: loaded regulatory.db is malformed or signature is missing/invalid
```

База при этом не применяется — остаётся «мировой» домен (00): каналы 12–13
только пассивно, `iw reg set RU` не действует.

В b022 лежит **2023.09.01** — последний выпуск, подписанный sforshee
(проверено: `openssl smime -verify -inform DER -in regulatory.db.p7s -content
regulatory.db -CAfile sforshee.x509.pem` → `Verification successful`;
отпечаток сертификата `8B:46:48:D9:5D:EF:A7:32:F5:B7:0C:8D:B8:18:EE:56:B5:FB:2F:2C`
совпадает с вшитым в ядро). Источник:
`https://mirrors.edge.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-2023.09.01.tar.xz`

### Если захочется свежую базу (2024+)

Нужна пересборка ядра с сертификатом wens:

```bash
# в дереве linux-6.6
mkdir -p /tmp/regkeys
openssl x509 -in wens.x509.pem -outform DER -out /tmp/regkeys/wens.x509.der
./scripts/config --set-str CFG80211_EXTRA_REGDB_KEYDIR /tmp/regkeys
./scripts/config -e CRYPTO_SHA256        # уже =y
make olddefconfig && make zImage modules
```

Проверить на плате: `dmesg | grep -i regdb` (строки про malformed быть не
должно) и `iw reg get` (должно показать `country RU` после `wifi reg RU`).
