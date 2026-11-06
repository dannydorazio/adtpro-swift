#!/bin/sh

# Copy a freshly built ip65 (https://github.com/cc65/ip65) into client/lib/ip65.
# Usage: client/tools/copyip65.sh [path-to-ip65]   (default: an ip65 checkout next to this repository)

CLIENT="$(cd "$(dirname "$0")/.." && pwd)"
IP65="${1:-$CLIENT/../../ip65}"

mkdir -p "$CLIENT/lib/ip65/inc"
cp "$IP65"/inc/* "$CLIENT/lib/ip65/inc"
cp "$IP65/ip65.lib" "$CLIENT/lib/ip65/ip65.lib"
cp "$IP65/drivers/a2combo.lib" "$CLIENT/lib/ip65/a2combo.lib"
cp "$IP65/drivers/a2uther2.lib" "$CLIENT/lib/ip65/a2uther2.lib"
