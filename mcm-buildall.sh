#!/bin/bash

# Script to build all supported cross and native compilers using
# https://github.com/richfelker/musl-cross-make

[ -z "$OUTPUT" ] && OUTPUT="$PWD/output"

make_toolchain()
{
  # Change title bar
  echo -en "\033]2;$TARGET-$TYPE\007"

  LP="$PATH"
  if [ -z "$TYPE" ]
  then
    OUTPUT="$PWD/host-$TARGET"
  else
    if [ "$TYPE" == static ]
    then
      HOST=i686-linux-musl
      [ "$TARGET" = "$HOST" ] && LP="$PWD/host-$HOST/bin:$LP"
      TYPE=cross
    else
      HOST="$TARGET"
      export NATIVE=y
    fi
    LP="$OUTPUT/$HOST-cross/bin:$LP"
    COMMON_CONFIG="CC=\"$HOST-gcc -static --static\" CXX=\"$HOST-g++ -static --static\""
    export -n HOST
    OUTPUT="$OUTPUT/$TARGET-$TYPE"
  fi

  [ ! -z "$NOCLEAN" ] && [ -e "$OUTPUT/bin/"*ld ] && return

  rm -rf build-"$TARGET" &&
  set -x &&
  PATH="$LP" make OUTPUT="$OUTPUT" TARGET="$TARGET" \
    GCC_CONFIG="--disable-nls --disable-libquadmath --disable-decimal-float $GCC_CONFIG" COMMON_CONFIG="$COMMON_CONFIG" \
    install -j$(($(nproc)+1))
  set +x
}

make_tuple()
{
  PART1=${1/:*/}
  PART3=${1/*:/}
  PART2=${1:$((${#PART1}+1)):$((${#1}-${#PART3}-${#PART1}-2))}

  for j in static native
  do
    echo === building $PART1
    TYPE=$j TARGET=${PART1}-linux-musl${PART2} GCC_CONFIG="$PART3" \
      make_toolchain 2>&1 | tee "$OUTPUT"/log/${PART1}-${j}.log
  done
}

[ -z "$NOCLEAN" ] && rm -rf "$OUTPUT" host-* build-* *.log
mkdir -p "$OUTPUT"/log

# Make i686 bootstrap compiler (no $TYPE, dynamically linked against host libc)
# then build i686 static first to create host compiler for other static builds
TARGET=i686-linux-musl make_toolchain 2>&1 | tee -a i686-host.log

# Without this i686-static build reuses the dynamically linked host build files.
[ -z "$NOCLEAN" ] && make clean

if [ $# -gt 0 ]
then
  for i in "$@"
  do
    make_tuple "$i"
  done
else
  for i in i686:: x86_64:: x86_64:x32: sh4::--enable-incomplete-targets \
         armv5l:eabihf:--with-arch=armv5t armv7l:eabihf:--with-arch=armv7-a \
         "armv7m:eabi:--with-arch=armv7-m --with-mode=thumb --disable-libatomic --enable-default-pie" \
         armv7r:eabihf:"--with-arch=armv7-r --enable-default-pie" \
         aarch64:eabi: i486:: sh2eb:fdpic:--with-cpu=mj2 s390x:: mipsel:: \
         mips:: powerpc:: microblaze:: mips64:: powerpc64:: powerpc64le::
  do
    make_tuple "$i"
  done
fi
