#!/bin/sh
# Copies a new lowercase UUID. A UUID is made only when a row runs, never while listing.
#   v4  random
#   v7  RFC 9562: 48-bit Unix milliseconds, version 7, variant 10, 74 random bits

case "$1" in
  v4)
    uuid=$(/usr/bin/uuidgen) || exit 1
    uuid=$(printf '%s' "$uuid" | tr 'A-F' 'a-f')
    ;;
  v7)
    uuid=$(/usr/bin/perl -MTime::HiRes=time -e '
      open my $random, "<", "/dev/urandom" or die "No random source\n";
      read($random, my $bytes, 10) == 10 or die "No random bytes\n";
      my @b = unpack "C10", $bytes;
      $b[0] = ($b[0] & 0x0f) | 0x70;
      $b[2] = ($b[2] & 0x3f) | 0x80;
      my $hex = sprintf "%012x" . ("%02x" x 10), int(time * 1000), @b;
      print join "-", unpack "A8 A4 A4 A4 A12", $hex;
    ') || exit 1
    ;;
  *)
    echo "Unknown version: $1" >&2
    exit 1
    ;;
esac
printf '{"copy":"%s"}\n' "$uuid"
