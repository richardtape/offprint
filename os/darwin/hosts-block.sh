# Sourced by os/darwin/host-setup.sh and host-undo.sh (as root) and by tests/hosts-block.test.sh.
# strip_hosts_block IN OUT BEGIN END
#   Writes IN to OUT without the BEGIN..END block and the one blank line before it.
#   Refuses (message on stderr, return 1, OUT removed) when the markers are not both
#   present or both absent, or when the result is empty or has no localhost line,
#   so a hand-edited /etc/hosts is never truncated.
strip_hosts_block() {
  local in="$1" out="$2" b="$3" e="$4" nb ne
  nb="$(grep -cxF -- "$b" "$in" || true)"
  ne="$(grep -cxF -- "$e" "$in" || true)"
  if [ "$nb" != "$ne" ] || [ "$nb" -gt 1 ]; then
    echo "refusing to touch $in: found $nb begin and $ne end markers (want both 0 or both 1)" >&2
    return 1
  fi
  awk -v b="$b" -v e="$e" '
    $0 == b { skip = 1; held = 0; next }
    skip && $0 == e { skip = 0; next }
    skip { next }
    held { print "" ; held = 0 }
    $0 == "" { held = 1; next }
    { print }
    END { if (held) print "" }
  ' "$in" > "$out"
  if [ ! -s "$out" ] || ! grep -q localhost "$out"; then
    echo "refusing to write $in: the result is empty or has no localhost line" >&2
    rm -f "$out"
    return 1
  fi
}
