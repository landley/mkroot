#!/bin/echo Use as an argument to mkroot.sh

download f3a20cbd8c140acbbba76eb6ca1f56a8812c321f \
  https://kernel.org/pub/linux/kernel/v4.x/linux-4.10.tar.gz

[ -z "$HOST" ] && HOST="${CROSS_BASE/-*/}"

if [ "$HOST" == x86_64 ]
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
else
  echo "Unknown \$HOST"
  exit 1
fi

# Collate arch-specific and generic parts of miniconfig
getconfig()
{
  echo "$KERNEL_CONFIG"
  cat << EOF
# CONFIG_EMBEDDED is not set
CONFIG_EARLY_PRINTK=y
CONFIG_BLK_DEV_INITRD=y"
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_MISC_FILESYSTEMS=y
CONFIG_DEVTMPFS=y
EOF
}

setupfor linux
make allnoconfig ARCH=$KARCH KCONFIG_ALLCONFIG=<(getconfig) &&
make ARCH=$KARCH CROSS_COMPILE="$CROSS_COMPILE" -j $(nproc) &&
cp "$VMLINUX" "$OUTPUT/$(basename "$VMLINUX")" &&
echo "$QEMU -nographic -no-reboot -append \"panic=1 HOST=$HOST $KARGS\""\
     "-kernel $(basename "$VMLINUX") -initrd $HOST-linux-musl-root.cpio.gz" \
     > "$OUTPUT"/qemu-$HOST.sh
cleanup

