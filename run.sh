#!/bin/bash

# Convenience wrapper to run an image from the output directory under qemu

if [ $# -lt 1 ]
then
  ls output | grep -v '[.]failed' | xargs
  exit
fi

ARCH="$1"
shift

cd output/$ARCH && ./qemu-$ARCH.sh "$@"
