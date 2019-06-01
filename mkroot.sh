#!/bin/bash

### Parse command line arguments. Clear and set up environment variables.

# Show usage for any unknown argument, ala "./mkroot.sh --help"
if [ "${1:0:1}" == '-' ] && [ "$1" != '-n' ] && [ "$1" != '-d' ] && [ "$1" != "-l" ]
then
  echo "usage: $0 [-n] [VAR=VALUE...] [MODULE...]"
  echo
  echo Create root filesystem in '$ROOT'
  echo
  echo "-n	Don't rebuild "'$ROOT, just build module(s) over it'
  echo "-d	Don't build, just download/verify source packages."
  echo "-l	Log every command run during build in cmdlog.txt"

  exit 1
fi

# Clear environment variables by restarting script w/bare minimum passed through
# => preserve proxy variables for those behind a proxy server.
[ -z "$NOCLEAR" ] &&
  exec env -i NOCLEAR=1 HOME="$HOME" PATH="$PATH" \
    $(env | grep -i _proxy=) \
    CROSS_COMPILE="$CROSS_COMPILE" CROSS_SHORT="$CROSS_SHORT" "$0" "$@"

# Loop collecting initial -x arguments. (Simple, can't collate ala -nl .)
while true
do
  [ "$1" == "-n" ] && N=1 && shift ||
  [ "$1" == "-d" ] && D=1 && shift ||
  [ "$1" == "-l" ] && WRAPDIR=wrap && shift || break
done

# Parse remaining args: assign NAME=VALUE to env vars, collect rest in $MODULES
while [ $# -ne 0 ]
do
  X="${1/=*/}"
  Y="${1#*=}"
  [ "${1/=/}" != "$1" ] && eval "export $X=\"\$Y\"" || MODULES="$MODULES $1"
  shift
done

# If we're cross compiling, set appropriate environment variables.
if [ -z "$CROSS_COMPILE" ]
then
  echo "Building natively"
  if ! cc --static -xc - -o /dev/null <<< "int main(void) {return 0;}"
  then
    echo "Warning: host compiler can't create static binaries." >&2
    sleep 3
  fi
else
  echo "Cross compiling"
  CROSS_PATH="$(dirname "$(which "${CROSS_COMPILE}cc")")"
  CROSS_BASE="$(basename "$CROSS_COMPILE")"
  [ -z "$CROSS_SHORT" ] && CROSS_SHORT="${CROSS_BASE/-*/}"
  if [ -z "$CROSS_PATH" ]
  then
    echo "no ${CROSS_COMPILE}cc in path" >&2
    exit 1
  fi
fi

# Work out absolute paths to working dirctories (can override on cmdline)
TOP="$PWD"
[ -z "$BUILD" ] && BUILD="$TOP/build"
[ -z "$DOWNLOAD" ] && DOWNLOAD="$TOP/download"
[ -z "$AIRLOCK" ] && AIRLOCK="$TOP/airlock"
[ -z "$OUTPUT" ] && OUTPUT="$TOP/output/${CROSS_SHORT:-host}"
[ -z "$ROOT" ] && ROOT="$OUTPUT/${CROSS_BASE}root"

[ -z "$N" ] && rm -rf "$ROOT"
MYBUILD="$BUILD/${CROSS_BASE:-host-}tmp"
mkdir -p "$MYBUILD" "$DOWNLOAD" || exit 1

### Functions to download, extract, and clean up after source packages.

# This is basically "wget $2"
download()
{
  # Grab source package from URL, confirming SHA1 hash.
  # You can stick extracted source in $DOWNLOAD and build will use that instead
  # Usage: download HASH URL

  FILE="$(basename "$2")"
  [ -d "$DOWNLOAD/${FILE/-*/}" ] && echo "$FILE" local && return 0

  X=0
  while true
  do
    [ "$(sha1sum "$DOWNLOAD/$FILE" 2>/dev/null | awk '{print $1}')" == "$1" ] &&
      echo "$FILE" confirmed &&
      break
    rm -f $DOWNLOAD/${FILE/-[0-9]*/}-[0-9]*
    [ $X -eq 1 ] && break
    X=1
    wget "$2" -O "$DOWNLOAD/$FILE"
  done
}

# This is basically "tar xvzCf $MYBUILD $DOWNLOAD/$1.tar.gz && cd $NEWDIR"
setupfor()
{
  # Extract source tarball (or snapshot a repo) to create disposable build dir.
  # Usage: setupfor PACKAGE

  PACKAGE="$(basename "$1")"
  echo === "$PACKAGE"
  tty -s && echo -en "\033]2;$CROSS_SHORT $STAGE_NAME $1\007"
  cd "$MYBUILD" && rm -rf "$PACKAGE" || exit 1
  if [ -d "$DOWNLOAD/$PACKAGE" ]
  then
    cp -la "$DOWNLOAD/$PACKAGE/." "$PACKAGE" &&
    cd "$PACKAGE" || exit 1
  else
    tar xvaf "$DOWNLOAD/$PACKAGE"-*.tar.* &&
    cd "$PACKAGE"-* || exit 1
  fi
}

# This is basically "rm -rf $NEWDIR" (remembered from setupfor)
cleanup()
{
  # Delete directory most recent setupfor created, or exit if build failed
  # Usage: cleanup

  [ $? -ne 0 ] && exit 1
  [ -z "$PACKAGE" ] && exit 1
  [ ! -z "$NO_CLEANUP" ] && return
  cd .. && rm -rf "$PACKAGE"* || exit 1
}

### Download source

download 4de23d92b6ab9393dd5e3da8135afe7b9d0b9e09 \
  http://landley.net/toybox/downloads/toybox-0.8.1.tar.gz

download 157d14d24748b4505b1a418535688706a2b81680 \
  http://www.busybox.net/downloads/busybox-1.24.1.tar.bz2

### Build airlock

# When cross compiling, provide known $PATH contents for build (mostly toybox),
# and filter out host $PATH stuff that confuses build

# We can also wrap the command $PATH and log every command line called.

if [ ! -z "$CROSS_COMPILE" ]
then
  # This is here so it happens even if airlock already exists
  if [ ! -z "$WRAPDIR" ]
  then
    WRAPDIR="$(readlink -f "$WRAPDIR")"
    [ ! -z "$WRAPLOG" ] && WRAPLOG="$(readlink -f "$WRAPLOG")" ||
      WRAPLOG="$OUTPUT/cmdlog.txt"
    export WRAPLOG
    mkdir -p "$(dirname "$WRAPLOG")"
  fi

  if [ ! -e "$AIRLOCK/toybox" ] || [ ! -z "$WRAPDIR" ] &&
     [ ! -e "$WRAPDIR/logwrapper" ]
  then
    echo === Create airlock dir

    MYBUILD="$BUILD" setupfor toybox
    CROSS_COMPILE= make defconfig &&
    CROSS_COMPILE= make &&
    CROSS_COMPILE= PREFIX="$AIRLOCK" make install_airlock || exit 1
    if [ ! -z "$WRAPDIR" ]
    then
      echo === Create command logging wrapper dir
      PATH="$CROSS_PATH:$AIRLOCK" WRAPDIR="$WRAPDIR" WRAPLOG="$WRAPLOG" \
        CROSS_COMPILE= scripts/record-commands "" || exit 1
    fi
    cleanup
  fi

  # busybox is broken, you can't switch this _off_ in the build...
  [ ! -e "$AIRLOCK/bzip2" ] && ln -s "$(which bzip2)" "$AIRLOCK/bzip2"

  export PATH="$CROSS_PATH:$AIRLOCK"
  [ ! -z "$WRAPDIR" ] && PATH="$WRAPDIR:$PATH"
fi

# -n skips rebuilding base system, adds to existing $ROOT
if [ ! -z "$N" ]
then
  if [ ! -d "$ROOT" ] || [ -z "$MODULES" ]
  then
    echo "-n needs an existing $ROOT and build files"
    exit 1
  fi

# -d skips everything but downloading packages
elif [ -z "$D" ]
then

### Create files and directories

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

if [ $$ -eq 1 ]
then
  # Don't allow deferred initialization to crap messages over the shell prompt
  echo 3 3 > /proc/sys/kernel/printk

  # Setup networking for QEMU (needs /proc)
  ifconfig eth0 10.0.2.15
  route add default gw 10.0.2.2
  [ "$(date +%s)" -lt 1000 ] && rdate 10.0.2.2 # or time-b.nist.gov
  [ "$(date +%s)" -lt 10000000 ] && ntpd -nq -p north-america.pool.ntp.org

  [ -z "$CONSOLE" ] &&
    CONSOLE="$(sed -rn 's@(.* |^)console=(/dev/)*([[:alnum:]]*).*@\3@p' /proc/cmdline)"

  [ -z "$HANDOFF" ] && HANDOFF=/bin/sh && echo Type exit when done.
  [ -z "$CONSOLE" ] && CONSOLE=console
  exec /sbin/oneit -c /dev/"$CONSOLE" $HANDOFF
else
  /bin/sh
  umount /dev/pts /dev /sys /proc
fi
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

### Build root filesystem binaries

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
EOF

make allnoconfig KCONFIG_ALLCONFIG=mini.conf &&
LDFLAGS=--static make install CONFIG_PREFIX="$ROOT" SKIP_STRIP=y -j $(nproc)
cleanup

fi # skipped by -n or -d

### Build modules listed on command line

for STAGE_NAME in $MODULES
do
  cd "$TOP" || exit 1
  if [ -z "$D" ]
  then
    . module/"$STAGE_NAME" || exit 1
  else
    eval "$(sed -n '/^download[^(]/{/\\$/b a;b b;:a;N;:b;p}' module/"$STAGE_NAME")"
  fi
done

# Remove build directory if it's empty.
rmdir "$MYBUILD" "$BUILD" 2>/dev/null
exit 0
