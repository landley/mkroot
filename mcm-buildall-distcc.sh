#!/bin/bash

DISTCC_HOSTS="Vostro-1500.local,lzo,cpp media.local,lzo,cpp ThunderPad,lzo,cpp"
SCPUs=5

# Script to build all supported cross and native compilers using
# https://github.com/richfelker/musl-cross-make

if [ "$1" == clean ]
then
  rm -rf "$OUTPUT" host-* *.log
  make clean
  exit
fi

# static linked i686 binaries are basically "poor man's x32".
BOOTSTRAP=i686-linux-musl

[ -z "$OUTPUT" ] && OUTPUT="$PWD/output"

make_toolchain()
{
  # Set cross compiler path
  LP="$PATH"
  if [ -z "$TYPE" ]
  then
    OUTPUT="$PWD/host-$TARGET"
    EXTRASUB=y
  else
    if [ "$TYPE" == static ]
    then
      HOST=$BOOTSTRAP
      [ "$TARGET" = "$HOST" ] && LP="$PWD/host-$HOST/bin:$LP"
      TYPE=cross
      EXTRASUB=y
      LP="$OUTPUT/$HOST-cross/bin:$LP"
    else
      HOST="$TARGET"
      export NATIVE=y
      LP="$OUTPUT/${RENAME:-$TARGET}-cross/bin:$LP"
    fi
    COMMON_CONFIG="CC=\"$HOST-gcc -static --static\" CXX=\"$HOST-g++ -static --static\""
    export -n HOST
    OUTPUT="$OUTPUT/${RENAME:-$TARGET}-$TYPE"
  fi

  [ -e "$OUTPUT/bin/"*ld ] && return

  # Change title bar

  echo === building $TARGET-$TYPE
  echo -en "\033]2;$TARGET-$TYPE\007"

  rm -rf build/"$TARGET" "$OUTPUT" &&
  if [ -z "$SCPUs" ]
  then
    SCPUs="$(nproc) * 2"
    [ "$SCPUs" != 1 ] && CPUS=$(($SCPUs+1))
  fi
  set -x &&
  PATH="$LP" pump make OUTPUT="$OUTPUT" TARGET="$TARGET" \
    CC=distcc GCC_CONFIG="--disable-nls --disable-libquadmath --disable-decimal-float $GCC_CONFIG" COMMON_CONFIG="$COMMON_CONFIG" \
    install -j${SCPUs} || exit 1
  set +x
  echo -e '#ifndef __MUSL__\n#define __MUSL__ 1\n#endif' \
    >> "$OUTPUT/${EXTRASUB:+$TARGET/}include/features.h"

  # Prevent i686-static build reusing dynamically linked host build files.
  [ -z "$TYPE" ] && make clean
}

# Expand compressed target into binutils/gcc "tuple" and call make_toolchain
make_tuple()
{
  PART1=${1/:*/}
  PART3=${1/*:/}
  PART2=${1:$((${#PART1}+1)):$((${#1}-${#PART3}-${#PART1}-2))}

  # Do we need to rename this toolchain after building it?
  RENAME=${PART1/*@/}
  [ "$RENAME" == "$PART1" ] && RENAME=
  PART1=${PART1/@*/}
  TARGET=${PART1}-linux-musl${PART2} 

  for TYPE in static native
  do
    TYPE=$TYPE TARGET=$TARGET GCC_CONFIG="$PART3" \
      make_toolchain 2>&1 | tee "$OUTPUT"/log/${RENAME:-$PART1}-${TYPE}.log
    if [ ! -z "$RENAME" ]
    then
      if [ "$TYPE" == static ]
      then
        CONTEXT="$OUTPUT/$RENAME-cross/bin"
        for i in "$CONTEXT/$TARGET"-*
        do
          X="$(echo $i | sed "s@.*/$TARGET-\([^-]*\)@\1@")"
          ln -s "$TARGET-$X" "$CONTEXT/$RENAME-$X"
        done
      fi
    fi
  done
}

if [ -z "$NOCLEAN" ]
then
  rm -rf build
fi
mkdir -p "$OUTPUT"/log

# Make bootstrap compiler (no $TYPE, dynamically linked against host libc)
# We build the rest of the cross compilers with this so they're linked against
# musl-libc, because glibc doesn't fully support static linking and dynamic
# binaries aren't really portable between distributions
TARGET=$BOOTSTRAP make_toolchain 2>&1 | tee -a i686-host.log

if [ $# -gt 0 ]
then
  rm -rf build
  for i in "$@"
  do
    make_tuple "$i"
  done
else
  for i in i686:: m68k:: x86_64:: x86_64@x32:x32: \
         sh4::--enable-incomplete-targets \
         armv4l:eabihf:"--with-arch=armv5t --with-float=soft" \
         armv5l:eabihf:--with-arch=armv5t armv7l:eabihf:--with-arch=armv7-a \
         "armv7m:eabi:--with-arch=armv7-m --with-mode=thumb --disable-libatomic --enable-default-pie" \
         armv7r:eabihf:"--with-arch=armv7-r --enable-default-pie" \
         aarch64:eabi: i486:: sh2eb:fdpic:--with-cpu=mj2 s390x:: mipsel:: \
         mips:: powerpc:: microblaze:: mips64:: powerpc64:: powerpc64le::
  do
    make_tuple "$i"
  done
fi
