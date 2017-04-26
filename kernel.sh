#!/bin/echo Use as an argument to mkroot.sh

download f3a20cbd8c140acbbba76eb6ca1f56a8812c321f \
  https://kernel.org/pub/linux/kernel/v4.x/linux-4.10.tar.gz

[ -z "$HOST" ] && HOST="${CROSS_BASE/-*/}"

# Target-specific info in an if/else staircase

if [ "$HOST" == powerpc ]
then
  QEMU="qemu-system-ppc -M g3beige"
  KARCH=powerpc
  KARGS="console=ttyS0"
  VMLINUX=vmlinux
  KERNEL_CONFIG="
CONFIG_ALTIVEC=y
CONFIG_PPC_PMAC=y
CONFIG_PPC_OF_BOOT_TRAMPOLINE=y
CONFIG_PPC601_SYNC_FIX=y
CONFIG_BLK_DEV_IDE_PMAC=y
CONFIG_BLK_DEV_IDE_PMAC_ATA100FIRST=y
CONFIG_MACINTOSH_DRIVERS=y
CONFIG_ADB=y
CONFIG_ADB_CUDA=y
CONFIG_NE2K_PCI=y
CONFIG_SERIO=y
CONFIG_SERIAL_PMACZILOG=y
CONFIG_SERIAL_PMACZILOG_TTYS=y
CONFIG_SERIAL_PMACZILOG_CONSOLE=y
CONFIG_BOOTX_TEXT=y
"
elif [ "$HOST" == sh4 ]
then
  QEMU="qemu-system-sh4 -M r2d -monitor null -serial null -serial stdio"
  KARCH=sh
  KARGS="console=ttySC1 noiotrap"
  VMLINUX=arch/sh/boot/zImage
  KERNEL_CONFIG="
CONFIG_CPU_SUBTYPE_SH7751R=y
CONFIG_MMU=y
CONFIG_MEMORY_START=0x0c000000
CONFIG_VSYSCALL=y
CONFIG_SH_FPU=y
CONFIG_SH_RTS7751R2D=y
CONFIG_RTS7751R2D_PLUS=y
CONFIG_SERIAL_SH_SCI=y
CONFIG_SERIAL_SH_SCI_CONSOLE=y
"
elif [ "$HOST" == x86_64 ]
then
  QEMU=qemu-system-x86_64
  KARCH=x86
  KARGS="console=ttyS0"
  VMLINUX=arch/x86/boot/bzImage
  KERNEL_CONFIG="
CONFIG_64BIT=y
CONFIG_ACPI=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
"
else
  echo "Unknown \$HOST"
  exit 1
fi

# Add generic info to arch-specific part of miniconfig
getminiconfig()
{
  echo "$KERNEL_CONFIG"
  echo "
# CONFIG_EMBEDDED is not set
CONFIG_EARLY_PRINTK=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_MISC_FILESYSTEMS=y
CONFIG_DEVTMPFS=y
"
}

# Build kernel

setupfor linux
make allnoconfig ARCH=$KARCH KCONFIG_ALLCONFIG=<(getminiconfig) &&
make ARCH=$KARCH CROSS_COMPILE="$CROSS_COMPILE" -j $(nproc) &&
cp "$VMLINUX" "$OUTPUT/$(basename "$VMLINUX")" &&
echo "$QEMU -nographic -no-reboot -m 256 -append \"panic=1 HOST=$HOST $KARGS\""\
     "-kernel $(basename "$VMLINUX") -initrd ${CROSS_BASE}root.cpio.gz" \
     > "$OUTPUT/qemu-$HOST.sh" &&
chmod +x "$OUTPUT/qemu-$HOST.sh"
cleanup

