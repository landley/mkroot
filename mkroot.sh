#!/bin/bash

if [ "${1:0:1}" == '-' ] && [ "$1" != '-n' ] && [ "$1" != '-d' ]
then
  echo "usage: $0 [-n] [VAR=VALUE] [MODULE...]"
  echo
  echo Create root filesystem in '$ROOT'
  echo
  echo "-n	Don't rebuild "'$ROOT, just build module(s) over it'

  exit 1
fi

# Clear environment variables, passing through the bare minimum.
[ -z "$NOCLEAR" ] &&
  exec env -i NOCLEAR=1 HOME="$HOME" PATH="$PATH" \
    CROSS_COMPILE="$CROSS_COMPILE" "$0" "$@"

# Parse command line arguments, assign name=value and collecting $OVERLAY list
while [ $# -ne 0 ]
do
  X="${1/=*/}"
  Y="${1#*=}"
  [ "${1/=/}" != "$1" ] && eval "$X=\$Y" || OVERLAY="$OVERLAY $1"
  shift
done

# Are we cross compiling?
if [ -z "$CROSS_COMPILE" ]
then
  echo "Building natively"
else
  echo "Cross compiling"
  CROSS_PATH="$(dirname "$(which "${CROSS_COMPILE}cc")")"
  CROSS_BASE="$(basename "$CROSS_COMPILE")"
  CROSS_SHORT="${CROSS_BASE/-*/}"
  if [ -z "$CROSS_PATH" ]
  then
    echo "no ${CROSS_COMPILE}cc in path" >&2
    exit 1
  fi
fi

# Absolute paths we can use from any directory
TOP="$PWD"
[ -z "$BUILD" ] && BUILD="$TOP/build"
[ -z "$OUTPUT" ] && OUTPUT="$TOP/output/${CROSS_SHORT:-host}"
[ -z "$ROOT" ] && ROOT="$OUTPUT/${CROSS_BASE}root"
[ -z "$DOWNLOAD" ] && DOWNLOAD="$TOP/download"
[ -z "$AIRLOCK" ] && AIRLOCK="$TOP/airlock"

[ "$1" == "-n" ] || rm -rf "$ROOT"
MYBUILD="$BUILD/${CROSS_BASE:-host-}tmp"
mkdir -p "$MYBUILD" "$DOWNLOAD" || exit 1

if ! cc --static -xc - <<< "int main(void) {return 0;}" -o "$BUILD"/hello
then
  echo "This compiler can't create a static binary." >&2
  exit 1
fi

# Grab source package from URL, confirming SHA1 hash
# Usage: download HASH URL
download()
{
  # You can stick extracted source in $DOWNLOAD and build will use that instead
  FILE="$(basename "$2")"
  [ -d "$DOWNLOAD/${FILE/-*/}" ] && echo "$FILE" local && return 0

  X=0
  while true
  do
    [ "$(sha1sum "$DOWNLOAD/$FILE" 2>/dev/null | awk '{print $1}')" == "$1" ] &&
      echo "$FILE" confirmed &&
      break
    rm -f $DOWNLOAD/${FILE/-*/}-*
    [ $X -eq 1 ] && break
    X=1
    wget "$2" -O "$DOWNLOAD/$FILE"
  done
}

# Extract source tarball (or snapshot repo) to create disposable build dir.
# Usage: setupfor PACKAGE
setupfor()
{
  PACKAGE="$(basename "$1")"
  echo === "$PACKAGE"
  tty -s && echo -en "\033]2;$CROSS_SHORT $STAGE_NAME $1\007"
  cd "$MYBUILD" && rm -rf "$PACKAGE" || exit 1
  if [ -d "$DOWNLOAD/$PACKAGE" ]
  then
    cp -la "$DOWNLOAD/$PACKAGE" "$PACKAGE" &&
    cd "$PACKAGE" || exit 1
  else
    tar xvaf "$DOWNLOAD/$PACKAGE"-*.tar.* &&
    cd "$PACKAGE"-* || exit 1
  fi
}

# Delete disposable build dir after a successful build, remembered from setupfor
# Usage: cleanup
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

# When cross compiling, provide known $PATH contents for build (mostly toybox),
# and filter out host $PATH stuff that confuses build

if [ ! -z "$CROSS_COMPILE" ]
then
  if [ ! -e "$AIRLOCK/toybox" ]
  then
    echo === Create airlock dir

    MYBUILD="$BUILD" setupfor toybox
    CROSS_COMPILE= make defconfig &&
    CROSS_COMPILE= make &&
    CROSS_COMPILE= PREFIX="$AIRLOCK" make install_airlock || exit 1
    cleanup
  fi
  export PATH="$CROSS_PATH:$AIRLOCK"
fi

# -n skips rebuilding base system, adds to existing $ROOT
if [ "$1" == "-n" ]
then
  shift
  if [ ! -d "$ROOT" ] || [ -z "$1" ]
  then
    echo "-n needs an existing $ROOT and build files"
    exit 1
  fi
else

echo === Create files and directories

rm -rf "$ROOT" &&
mkdir -p "$ROOT"/{etc,tmp,proc,sys,dev,home,mnt,root,usr/{bin,sbin,lib},var} &&
chmod a+rwxt "$ROOT"/tmp &&
ln -s usr/bin "$ROOT/bin" &&
ln -s usr/sbin "$ROOT/sbin" &&
ln -s usr/lib "$ROOT/lib" &&

cat > "$ROOT"/init << 'EOF' &&
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
exec /sbin/oneit -c /dev/"$CONSOLE" $HANDOFF
EOF
chmod +x "$ROOT"/init &&

cat > "$ROOT"/etc/passwd << 'EOF' &&
root::0:0:root:/home/root:/bin/sh
guest:x:500:500:guest:/home/guest:/bin/sh
nobody:x:65534:65534:nobody:/proc/self:/dev/null
EOF

cat > "$ROOT"/etc/group << 'EOF' &&
root:x:0:
guest:x:500:
EOF

echo "nameserver 8.8.8.8" > "$ROOT"/etc/resolv.conf || exit 1

# toybox

setupfor toybox
make defconfig || exit 1
# Work around musl-libc design flaw
if [ "${CROSS_BASE/fdpic//}" != "$CROSS_BASE" ]
then
  sed -i 's/.*\(CONFIG_TOYBOX_MUSL_NOMMU_IS_BROKEN\).*/\1=y/' .config || exit 1
fi
LDFLAGS=--static PREFIX="$ROOT" make toybox install
cleanup

# todo: eliminate busybox

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
LDFLAGS=--static make install CONFIG_PREFIX="$ROOT" SKIP_STRIP=y -j $(nproc)
cleanup

fi # -n

# Build overlays(s)
for STAGE_NAME in $OVERLAY
do
  cd "$TOP" &&
  . module/"$STAGE_NAME" || exit 1
  shift
done
