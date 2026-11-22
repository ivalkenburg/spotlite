#!/bin/sh
# Finds files whose name contains the query, under the configured folder. The action
# streams ("stream": true): each file is printed as its own JSON line the moment find
# reaches it, so the first ones show while find is still walking the folder. Output stops
# after 200 files, which also ends find. Hidden folders and ~/Library are skipped.

folder="$(printf '%s' "${SPOTLITE_CONFIG:-}" | jq -r '.folder // empty' 2>/dev/null)"
folder="${folder:-$HOME}"
# The query is matched literally, not as a pattern.
pattern="*$(printf '%s' "$1" | sed 's/[][*?\\]/\\&/g')*"

find "$folder" \( -name '.*' -o -path "$HOME/Library" -o -name node_modules \) -prune \
  -o -iname "$pattern" -print0 2>/dev/null |
/usr/bin/perl -0 -MJSON::PP -MEncode=decode,FB_CROAK -e '
  my $json = JSON::PP->new->utf8;
  my $home = decode("UTF-8", $ENV{HOME});
  my $count = 0;
  $| = 1;
  while (<STDIN>) {
    chomp;
    my $path = eval { decode("UTF-8", $_, FB_CROAK) };
    next unless defined $path;
    my ($parent, $name) = $path =~ m{^(.*)/([^/]*)$}s;
    $parent = "/" if $parent eq "";
    $parent =~ s{^\Q$home\E(?=/|$)}{~};
    print $json->encode({
      id => $path, title => $name, subtitle => $parent, icon => $path,
      action => {type => "open", url => $path}
    }), "\n";
    last if ++$count == 200;
  }'
