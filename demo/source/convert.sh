#!/bin/bash

source_dir=$(readlink -f "$(dirname "$0")")
demo_dir=$(dirname "$source_dir")

(for f in "$source_dir"/*.webm; do echo "file '$f'"; done) | ffmpeg -f concat -safe 0 -i /dev/stdin -vf "fps=2,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$demo_dir/demo.gif" -y
