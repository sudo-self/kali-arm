#!/usr/bin/env bash
#
# Kali Linux ARM build-script for Raspberry Pi Zero 2 W (Pi-Tail) (32-bit)
# Source: https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a supported device - which you can find pre-generated images on: https://www.kali.org/get-kali/
# More information: https://www.kali.org/docs/arm/raspberry-pi-zero-2-w-pi-tail/
#

# Hardware model
export hw_model=${hw_model:-"raspberry-pi-zero-2-w-pitail"}

# Architecture
export architecture=${architecture:-"armhf"}

./raspberry-pi-zero-w-pitail.sh --arch armhf "$@"
