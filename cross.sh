#!/bin/bash

# Convenience wrapper to set CROSS_COMPILE variable to musl-cross-make pathname
# using "mcm" symlink to musl-cross-make output directory.

# Usage: ./cross.sh TARGET ./mkroot.sh 
# With no arguments, lists available targets.
# Use target "all" to iterate through all targets.

MCM="$(dirname "$(readlink -f "$0")")"/mcm
if [ ! -d "$MCM" ]
then
  echo "Create symlink 'mcm' to musl-cross-make output directory"
  exit 1
fi

unset X Y

# Display target list?
list()
{
  ls "$MCM" | sed 's/-.*//' | sort -u | xargs
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

Y=$(readlink -f "$MCM"/$X-*cross)
X=$(basename "$Y")
X="$Y/bin/${X/-cross/-}"
[ ! -e "${X}cc" ] && echo "${X}cc not found" && exit 1

CROSS_COMPILE="$X" "$@"
