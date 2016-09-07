#!/bin/bash

CONTROLPORT=$1

cat <<'EOF' | nc localhost $CONTROLPORT
authenticate ""
signal newnym
quit
EOF
