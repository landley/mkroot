#!/bin/bash

# Convenience wrapper to set CROSS_COMPILE variable from short name using "ccc"
# symlink (Cross cc) to directory of cross compilers named $TARGET-*-cross.
# Tested with musl-cross-make output directory.

# Usage: ./cross.sh TARGET make defconfig toybox_clean root
# With no arguments, lists available targets.
# Use target "all" to iterate through all targets.

CCC="$(dirname "$(readlink -f "$0")")"/ccc
if [ ! -d "$CCC" ]
then
  echo "Create symlink 'ccc' to cross compiler directory"
  exit 1
fi

unset X Y

# Display target list?
list()
{
  ls "$CCC" | sed 's/-.*//' | sort -u | xargs
}
[ $# -eq 0 ] && list && exit

X="$1"
shift

# build all targets?
if [ "$X" == all ]
then
  for i in $(list)
  do
    mkdir -p output/$i
    {
      "$0" $i "$@" 2>&1 || mv output/$i{,.failed}
    } | tee output/$i/log.txt
  done

  exit
fi

# Call command with CROSS_COMPILE= as its first argument

Y=$(readlink -f "$CCC"/$X-*cross)
X=$(basename "$Y")
X="$Y/bin/${X/-cross/-}"
[ ! -e "${X}cc" ] && echo "${X}cc not found" && exit 1

CROSS_COMPILE="$X" "$@"
