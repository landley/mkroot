#!/bin/bash

# Convenience wrapper to run an image from the output directory under qemu

if [ $# -lt 1 ]
then
  if [ $(ls -1 output | wc -l) -eq 1 ]
  then
    ARCH=$(ls -1 output)
    shift
  else
    ls output | grep -v '[.]failed' | xargs
    exit
  fi
else
  ARCH="$1"
  shift
fi

cd output/$ARCH && ./qemu-$ARCH.sh "$@"
