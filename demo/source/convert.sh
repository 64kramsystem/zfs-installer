#!/bin/bash

(for f in *.webm; do echo "file '$PWD/$f'"; done) | ffmpeg -f concat -safe 0 -i /dev/stdin -vf "fps=2,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" -loop -1 "$PWD/../demo.gif" -y
