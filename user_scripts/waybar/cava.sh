#!/bin/bash

trap 'kill 0' EXIT SIGTERM SIGINT

cava -p <(cat << EOF
[general]
bars = 18
framerate = 60

[output]
method = raw
raw_target = /dev/stdout
data_format = ascii
ascii_max_range = 7
EOF
) | sed -u 's/;//g;y/01234567/▁▂▃▄▅▆▇█/'
