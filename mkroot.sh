#!/bin/bash

if [ "${1:0:1}" == '-' ] && [ "$1" != '-n' ] && [ "$1" != '-d' ]
then
  echo "usage: $0 [-nd] [OVERLAY...]"
  echo
  echo Create root filesystem in '$OUT'
  echo
  echo "-n	Don't rebuild "'$OUT, just build overlay(s)'
  echo '-d	Install libc and dynamic linker to $OUT'

  exit 1
fi

# Are we cross compiling?

if [ -z "$CROSS_COMPILE" ]
then
  echo "Building natively"
else
  echo "Cross compiling"
  CROSS_PATH="$(dirname "$(which "${CROSS_COMPILE}cc")")"
  CROSS_BASE="$(basename "$CROSS_COMPILE")"
  if [ -z "$CROSS_PATH" ]
  then
    echo "no ${CROSS_COMPILE}cc in path" >&2
    exit 1
  fi
fi

# Setup absolute paths (cd here to reset)
TOP="$PWD"
[ -z "$BUILD" ] && BUILD="$TOP/build"
[ -z "$OUTPUT" ] && OUTPUT="$TOP/output"
[ -z "$OUT" ] && OUT="$OUTPUT/${CROSS_BASE}root"
[ -z "$PACKAGES" ] && PACKAGES="$TOP/packages"
[ -z "$AIRLOCK" ] && AIRLOCK="$TOP/airlock"

MYBUILD="$BUILD"
[ ! -z "$CROSS_BASE" ] && MYBUILD="$BUILD/${CROSS_BASE}tmp"

[ "$1" == "-n" ] || rm -rf "$OUT"
mkdir -p "$MYBUILD" "$PACKAGES" || exit 1

if ! cc --static -xc - <<< "int main(void) {return 0;}" -o "$BUILD"/hello
then
  echo "Your toolchain cannot compile a static hello world." >&2
  exit 1
fi

# Grab source package from URL, confirming SHA1 hash
download()
{
  # You can stick extracted source in "packages" and build will use that instead
  FILE="$(basename "$2")"
  [ -d "$PACKAGES/${FILE/-*/}" ] && echo "$FILE" local && return 0

  X=0
  while true
  do
    [ "$(sha1sum "packages/$FILE" 2>/dev/null | awk '{print $1}')" == "$1" ] &&
      echo "$FILE" confirmed &&
      break
    [ $X -eq 1 ] && break
    X=1
    rm -f packages/${FILE/-*/}-*
    wget "$2" -O "packages/$FILE"
  done
}

# Extract source tarball (or snapshot repo) to create disposable build dir.
setupfor()
{
  PACKAGE="$(basename "$1")"
  cd "$MYBUILD" && rm -rf "$PACKAGE" || exit 1
  if [ -d "$PACKAGES/$PACKAGE" ]
  then
    cp -la "$PACKAGES/$PACKAGE" "$PACKAGE" &&
    cd "$PACKAGE" || exit 1
  else
    tar xvaf "$PACKAGES/$PACKAGE"-*.tar.* &&
    cd "$PACKAGE"-* || exit 1
  fi
}

# Delete disposable build dir after a successful build
cleanup()
{
  [ $? -ne 0 ] && exit 1
  [ -z "$PACKAGE" ] && exit 1
  cd .. && rm -rf "$PACKAGE"* || exit 1
}

echo === download source

download f3d9f5396a210fb2ad7d6309acb237751c50812f \
  http://landley.net/toybox/downloads/toybox-0.7.3.tar.gz

download 157d14d24748b4505b1a418535688706a2b81680 \
  http://www.busybox.net/downloads/busybox-1.24.1.tar.bz2

# Provide known $PATH contents for build (mostly toybox), and filter out
# host $PATH stuff that confuses build

if [ ! -e "$AIRLOCK/toybox" ]
then
  echo === airlock

  MYBUILD="$BUILD" setupfor toybox
  CROSS_COMPILE= make defconfig &&
  CROSS_COMPILE= make -j $(nproc) &&
  CROSS_COMPILE= PREFIX="$AIRLOCK" make install_airlock || exit 1
  cleanup
fi
export PATH="$CROSS_PATH:$AIRLOCK"

# -n skips rebuilding base system, adds to existing $OUT
if [ "$1" == "-n" ]
then
  shift
  if [ ! -d "$OUT" ] || [ -z "$1" ]
  then
    echo "-n without existing $OUT or build files"
    exit 1
  fi
else

echo === Create files and directories

rm -rf "$OUT" &&
mkdir -p "$OUT"/{etc,tmp,proc,sys,dev,home,mnt,root,usr/{bin,sbin,lib},var} &&
chmod a+rwxt "$OUT"/tmp &&
ln -s usr/bin "$OUT/bin" &&
ln -s usr/sbin "$OUT/sbin" &&
ln -s usr/lib "$OUT/lib" &&

cat > "$OUT"/init << 'EOF' &&
#!/bin/sh

export HOME=/home
export PATH=/bin:/sbin

mountpoint -q proc || mount -t proc proc proc
mountpoint -q sys || mount -t sysfs sys sys
if ! mountpoint -q dev
then
  mount -t devtmpfs dev dev || mdev -s
  mkdir -p dev/pts
  mountpoint -q dev/pts || mount -t devpts dev/pts dev/pts
fi

# Setup networking for QEMU (needs /proc)
ifconfig eth0 10.0.2.15
route add default gw 10.0.2.2
[ "$(date +%s)" -lt 1000 ] && rdate 10.0.2.2 # or time-b.nist.gov
[ "$(date +%s)" -lt 10000000 ] && ntpd -nq -p north-america.pool.ntp.org

[ -z "$CONSOLE" ] &&
  CONSOLE="$(sed -n 's@.* console=\(/dev/\)*\([^ ]*\).*@\2@p' /proc/cmdline)"

[ -z "$HANDOFF" ] && HANDOFF=/bin/sh && echo Type exit when done.
[ -z "$CONSOLE" ] && CONSOLE=console
exec /sbin/oneit -c /dev/"$CONSOLE" "$HANDOFF"
EOF
chmod +x "$OUT"/init &&

cat > "$OUT"/etc/passwd << 'EOF' &&
root::0:0:root:/home/root:/bin/sh
guest:x:500:500:guest:/home/guest:/bin/sh
EOF

cat > "$OUT"/etc/group << 'EOF' &&
root:x:0:
guest:x:500:
EOF

echo "nameserver 8.8.8.8" > "$OUT"/etc/resolv.conf || exit 1

echo === install toybox

setupfor toybox
make defconfig || exit 1
# Work around musl-libc design flaw
if [ "${CROSS_BASE/fdpic//}" != "$CROSS_BASE" ]
then
  sed -i 's/.*\(CONFIG_TOYBOX_MUSL_NOMMU_IS_BROKEN\).*/\1=y/' .config || exit 1
fi
LDFLAGS=--static PREFIX="$OUT" make toybox install
cleanup

echo === install busybox

setupfor busybox
cat > mini.conf << EOF
CONFIG_NOMMU=y
CONFIG_DESKTOP=y
CONFIG_LFS=y
CONFIG_SHOW_USAGE=y
CONFIG_FEATURE_VERBOSE_USAGE=y
CONFIG_LONG_OPTS=y

CONFIG_BUNZIP2=y
CONFIG_BZIP2=y
CONFIG_GUNZIP=y
CONFIG_GZIP=y
CONFIG_UNXZ=y

CONFIG_TAR=y
CONFIG_FEATURE_TAR_CREATE=y
CONFIG_FEATURE_TAR_AUTODETECT=y
CONFIG_FEATURE_TAR_GNU_EXTENSIONS=y
CONFIG_FEATURE_TAR_OLDGNU_COMPATIBILITY=y
CONFIG_FEATURE_TAR_LONG_OPTIONS=y
CONFIG_FEATURE_TAR_FROM=y
CONFIG_FEATURE_SEAMLESS_BZ2=y
CONFIG_FEATURE_SEAMLESS_GZ=y
CONFIG_FEATURE_SEAMLESS_XZ=y

CONFIG_ROUTE=y

CONFIG_HUSH=y
CONFIG_HUSH_BASH_COMPAT=y
CONFIG_HUSH_BRACE_EXPANSION=y
CONFIG_HUSH_HELP=y
CONFIG_HUSH_INTERACTIVE=y
CONFIG_HUSH_SAVEHISTORY=y
CONFIG_HUSH_JOB=y
CONFIG_HUSH_TICK=y
CONFIG_HUSH_IF=y
CONFIG_HUSH_LOOPS=y
CONFIG_HUSH_CASE=y
CONFIG_HUSH_FUNCTIONS=y
CONFIG_HUSH_LOCAL=y
CONFIG_HUSH_RANDOM_SUPPORT=y
CONFIG_HUSH_EXPORT_N=y
CONFIG_HUSH_MODE_X=y
CONFIG_FEATURE_SH_IS_HUSH=y
CONFIG_FEATURE_BASH_IS_NONE=y

CONFIG_SH_MATH_SUPPORT=y
CONFIG_SH_MATH_SUPPORT_64=y
CONFIG_FEATURE_SH_EXTRA_QUIET=y

CONFIG_FEATURE_EDITING=y
CONFIG_FEATURE_TAB_COMPLETION=y
CONFIG_FEATURE_EDITING_FANCY_PROMPT=y
CONFIG_FEATURE_EDITING_ASK_TERMINAL=y

CONFIG_WGET=y
CONFIG_FEATURE_WGET_STATUSBAR=y

CONFIG_PING=y

CONFIG_VI=y
CONFIG_FEATURE_VI_COLON=y
CONFIG_FEATURE_VI_YANKMARK=y
CONFIG_FEATURE_VI_SEARCH=y
CONFIG_FEATURE_VI_USE_SIGNALS=y
CONFIG_FEATURE_VI_DOT_CMD=y
CONFIG_FEATURE_VI_READONLY=y
CONFIG_FEATURE_VI_SETOPTS=y
CONFIG_FEATURE_VI_SET=y
CONFIG_FEATURE_VI_WIN_RESIZE=y
CONFIG_FEATURE_VI_ASK_TERMINAL=y
CONFIG_FEATURE_VI_OPTIMIZE_CURSOR=y
EOF

make allnoconfig KCONFIG_ALLCONFIG=mini.conf &&
LDFLAGS=--static make install CONFIG_PREFIX="$OUT" SKIP_STRIP=y -j $(nproc)
cleanup

if [ "$1" == "-d" ]
then

  echo === Install dynamic libraries

  LIBLIST="c crypt dl m pthread resolv rt util"
  # Is toolchain static only?
  echo 'int main(void) {;}' > hello.c &&
  ${CROSS_COMPILE}cc hello.c || exit 1
  LDSO=$(toybox file a.out | sed 's/.* dynamic [(]\([^)]*\).*/\1/')
  rm -f a.out hello.c
  i="$(${CROSS_COMPILE}cc -print-file-name=$(basename "$LDSO"))"
#  if [ "${i/\//}" == "$i" ]
#  then
#    ln -s "/lib/libc.so" "$OUT/$LDSO" "$OUT/usr/bin/ldd" || exit 1
#  else
#    LIBLIST="$(basname "LDSO") $LIBLIST
#  fi

  for i in $LIBLIST
  do
    L="$(${CROSS_COMPILE}cc -print-file-name=lib${i}.so)"
    [ "$L" == "${L/\///}" ] && continue
    cp "$L" "$OUT/lib/$(basename "$L")" || exit 1
  done
fi

fi # -n

# Build additional package(s)
if [ ! -z "$OVERLAY" ]
then
  cd "$TOP" &&
  . $OVERLAY || exit 1
fi

echo === create "${CROSS_BASE}root.cpio.gz"

(cd "$OUT" && find . | cpio -o -H newc | gzip) > \
  "$OUTPUT/${CROSS_BASE}root.cpio.gz"

echo === Now build kernel with CONFIG_INITRAMFS_SOURCE="\"$OUT\""
