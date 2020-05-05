#!/bin/bash

c_fifo_filename="/tmp/target_image.fifo"
c_root_pool_mount=/mnt

echo "Restoring the target image..."

# shellcheck disable=SC2002 # xz doesn't accept as input a fifo, and reverting the commands orde
# is ugly.
cat "$c_fifo_filename" | xz -d | tar xv -C "$c_root_pool_mount"

echo
