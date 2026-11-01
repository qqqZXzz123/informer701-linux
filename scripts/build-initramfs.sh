#!/bin/bash
# Build the diagnostic rescue initramfs (Alpine minirootfs + i2c-tools + memtester + devmem2)
set -euo pipefail
cd /tmp/w

R=initramfs

# --- extra packages ---------------------------------------------------------
for p in i2c-tools memtester devmem2; do
    d=$(mktemp -d)
    tar -xzf $p.apk -C $d
    (cd $d && tar -cf - --exclude='.PKGINFO' --exclude='.SIGN*' . ) | (cd $R && tar -xf -)
    rm -rf $d
done
chmod 755 $R/usr/bin/i2c* $R/usr/sbin/i2c* $R/usr/bin/memtester $R/usr/bin/devmem2 2>/dev/null || true

# --- device nodes needed before /init runs ---------------------------------
mkdir -p $R/dev
[ -e $R/dev/console ] || mknod -m 600 $R/dev/console c 5 1
[ -e $R/dev/null    ] || mknod -m 666 $R/dev/null    c 1 3
[ -e $R/dev/tty     ] || mknod -m 666 $R/dev/tty     c 5 0
[ -e $R/dev/zero    ] || mknod -m 666 $R/dev/zero    c 1 5

# --- /init ------------------------------------------------------------------
cat > $R/init <<'INIT'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin
export PATH TERM=linux
mount -t proc     proc     /proc
mount -t sysfs    sys      /sys
mount -t devtmpfs dev      /dev      2>/dev/null
mount -t devpts   devpts   /dev/pts  2>/dev/null
mount -t tmpfs    tmp      /tmp
mount -t tmpfs    run      /run
mount -t debugfs  debug    /sys/kernel/debug 2>/dev/null
mkdir -p /dev/pts /dev/shm

CMD=" $(cat /proc/cmdline) "

echo
echo "=================================================================="
echo "  Informer 701 (Allwinner A10) - rescue / diagnostic initramfs"
echo "=================================================================="
echo "  cmdline:$CMD"

# ---- hb=1 : heartbeat + watchdog petter (the "is the CPU dead?" test) ------
case "$CMD" in
  *" hb=1 "*)
    echo "[hb] heartbeat + watchdog petter enabled"
    (
      if [ -e /dev/watchdog ]; then
        exec 9>/dev/watchdog
        n=0
        while :; do
          n=$((n+1))
          printf '1' >&9
          echo "[hb] ALIVE $n  up=$(cut -d' ' -f1 /proc/uptime)"
          sleep 2
        done
      else
        echo "[hb] !! /dev/watchdog NOT present"
        n=0
        while :; do
          n=$((n+1)); echo "[hb] ALIVE $n up=$(cut -d' ' -f1 /proc/uptime)"; sleep 2
        done
      fi
    ) &
    ;;
esac

sleep 2
echo
echo "------------------ auto diagnostics ------------------"
diag 2>&1
echo "------------------ end diagnostics -------------------"
echo
echo "Commands:  diag | pmic | memtest [MB] | clk | regs | mmcinfo | dmesg"
echo "           (save the output and send it back)"
echo
exec /bin/sh
INIT
chmod 755 $R/init

mkdir -p $R/usr/local/bin

cat > $R/usr/local/bin/diag <<'EOF'
#!/bin/sh
echo "== uname"; uname -a
echo "== cmdline"; cat /proc/cmdline
echo "== uptime"; cat /proc/uptime
echo "== meminfo"; head -4 /proc/meminfo
echo
echo "== dmesg: axp / pmic / regulator / i2c =="
dmesg | grep -i -e axp -e pmic -e regulator -e i2c -e twi
echo
echo "== dmesg: mmc =="
dmesg | grep -i -e mmc
echo
echo "== dmesg: cpufreq =="
dmesg | grep -i -e cpufreq -e unlisted
echo
echo "== dmesg tail 30 =="
dmesg | tail -30
echo
echo "== /proc/interrupts =="
cat /proc/interrupts
echo
echo "== regulator_summary =="
cat /sys/kernel/debug/regulator/regulator_summary 2>&1
echo
echo "== clk_summary (pll/cpu/ahb/apb/mmc) =="
grep -E "enable|pll|cpu|ahb|apb|mmc" /sys/kernel/debug/clk/clk_summary 2>&1 | head -40
echo
echo "== i2cdetect -y 0 (0x34 = AXP209) =="
i2cdetect -y 0 2>&1
echo
echo "== AXP209 registers over I2C0 =="
printf "chip id  reg03 (expect 0x21): "; i2cget -f -y 0 0x34 0x03 2>&1
printf "power st reg00              : "; i2cget -f -y 0 0x34 0x00 2>&1
printf "DCDC2    reg23 (VDD-CPU)    : "; i2cget -f -y 0 0x34 0x23 2>&1
printf "DCDC3    reg24 (VDD-INT)    : "; i2cget -f -y 0 0x34 0x24 2>&1
printf "LDO2     reg29 (AVCC)       : "; i2cget -f -y 0 0x34 0x29 2>&1
printf "DCDC en  reg12              : "; i2cget -f -y 0 0x34 0x12 2>&1
echo "  (DCDC2: 0.70 V + 25 mV per step, e.g. 0x1c = 1.40 V)"
echo
echo "== cpuinfo =="
head -12 /proc/cpuinfo
EOF

cat > $R/usr/local/bin/pmic <<'EOF'
#!/bin/sh
# Hammer the AXP209 100 times: is the I2C link stable or intermittent?
echo "reading AXP209 chip id (reg 0x03) 100 times:"
n=0; fail=0
while [ $n -lt 100 ]; do
    v=$(i2cget -f -y 0 0x34 0x03 2>/dev/null) || v="ERR"
    [ "$v" = "ERR" ] && fail=$((fail+1))
    printf "%s " "$v"
    n=$((n+1))
    usleep 100000 2>/dev/null || :
done
echo
echo "failures: $fail / 100"
EOF

cat > $R/usr/local/bin/memtest <<'EOF'
#!/bin/sh
MB=${1:-32}
PASSES=${2:-1}
echo "memtester ${MB}M x${PASSES}"
echo "If this reports errors or hangs, DRAM or the CPU/DRAM voltage is the problem."
memtester ${MB}M ${PASSES}
EOF



cat > $R/usr/local/bin/mmcinfo <<'EOF'
#!/bin/sh
echo "== block devices =="
ls -l /sys/block/ 2>&1
echo "== mmc hosts =="
for h in /sys/class/mmc_host/*; do echo "-- $h"; cat $h/uevent 2>/dev/null; done
echo "== driver bindings =="
ls -l /sys/bus/platform/drivers/sunxi-mmc/ 2>&1
echo
echo "Useful manual tests:"
echo "  echo 1c0f000.mmc > /sys/bus/platform/drivers/sunxi-mmc/unbind"
echo "  echo 1c0f000.mmc > /sys/bus/platform/drivers/sunxi-mmc/bind"
echo "  dmesg | tail -20   # after each step"
EOF

cat > $R/etc/motd <<'EOF'
Informer 701 (A10) rescue initramfs.
  whichboot  - каким пунктом меню загружена плата
  savelog    - diag -> /boot/diag-<build>-<пункт>.txt (примонтирует /boot сам)
  diag       - full hardware report (send the output back!)
  pmic       - 100x AXP209 read test (I2C stability)
  memtest 32 - DRAM test
  clk        - clock tree
  regs       - raw register dump (CCU / UART0 / MMC0)
  mmcinfo    - mmc host state
EOF

# --- shared helpers: identical to the ones installed in the rootfs ----------
SHARED="$(cd "$(dirname "$0")/.." && pwd)/rootfs-files/usr-local-bin"
for s in i2cbus diag pmic pmic-regs clk regs info whichboot savelog; do
    cp "$SHARED/$s" "$R/usr/local/bin/$s"
    echo "   + $s (shared)"
done
echo "${BUILD:-dev}-initramfs" > "$R/etc/build-id"
# mmcinfo stays initramfs-only (SD is not mounted here)

chmod 755 $R/usr/local/bin/*
du -sh $R

# --- pack -------------------------------------------------------------------
rm -f rescue2.cpio.gz
(cd $R && find . | LC_ALL=C sort | cpio -o -H newc --quiet) | gzip -9 > rescue2.cpio.gz
ls -l rescue2.cpio.gz
echo "== initramfs done =="
