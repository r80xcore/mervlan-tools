#!/bin/sh
PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

# Merlin-safe command detection
if ! type merv_has >/dev/null 2>&1; then
  merv_has() { type "$1" >/dev/null 2>&1; }
  merv_cmd() {
    _merv_c="$1"
    case "$_merv_c" in
      */*) [ -x "$_merv_c" ] && { printf '%s\n' "$_merv_c"; return 0; } ;;
    esac
    _merv_oldIFS="$IFS"; IFS=:
    for _merv_d in $PATH; do
      [ -z "$_merv_d" ] && _merv_d="."
      [ -x "$_merv_d/$_merv_c" ] && { IFS="$_merv_oldIFS"; printf '%s\n' "$_merv_d/$_merv_c"; return 0; }
    done
    IFS="$_merv_oldIFS"
    return 1
  }
fi

echo "Ready. Press Enter to run (Ctrl+C cancels)."
read -r _

ETHCTL=""
if merv_has ethctl; then
  ETHCTL="$(merv_cmd ethctl 2>/dev/null)" || ETHCTL="ethctl"
fi

WAN="$(nvram get wan_ifname 2>/dev/null)"
[ -z "$WAN" ] && WAN="$(nvram get wan0_ifname 2>/dev/null)"

LAN_TRUNK="$(nvram get lan_ifnames 2>/dev/null \
  | tr ' ' '\n' | grep -E '^eth[0-9]+' | head -n1)"

if [ -z "$LAN_TRUNK" ] && [ -d /sys/class/net/br0/brif ]; then
  LAN_TRUNK="$(ls -1 /sys/class/net/br0/brif 2>/dev/null \
    | grep -E '^eth[0-9]+' | head -n1)"
fi

echo "MODEL=$(nvram get productid 2>/dev/null) BUILD=$(nvram get buildno 2>/dev/null) EXT=$(nvram get extendno 2>/dev/null)"
echo "WAN_IFNAME=$WAN"
echo "LAN_TRUNK=$LAN_TRUNK"
echo "ETHCTL=${ETHCTL:-"(not found)"}"
echo ""

echo "---BR0 MEMBERS---"
if [ -d /sys/class/net/br0/brif ]; then
  ls -1 /sys/class/net/br0/brif | sort
else
  echo "no br0"
fi
echo ""

echo "---ETHCTL PHY-CROSSBAR---"
if [ -n "$ETHCTL" ]; then
  [ -n "$LAN_TRUNK" ] && "$ETHCTL" "$LAN_TRUNK" phy-crossbar 2>/dev/null || true
  "$ETHCTL" bcmsw phy-crossbar 2>/dev/null || true
else
  echo "no ethctl"
fi
echo ""

# Find which sub_port# values exist by probing port 0..31
PORTS=""
if [ -n "$LAN_TRUNK" ] && [ -n "$ETHCTL" ]; then
  p=0
  while [ $p -le 31 ]; do
    if "$ETHCTL" "$LAN_TRUNK" media-type port "$p" 2>/dev/null | grep -q 'Link is'; then
      PORTS="$PORTS $p"
    fi
    p=$((p + 1))
  done
fi
PORTS="$(echo "$PORTS" | sed 's/^ *//; s/ *$//')"

echo "---DETECTED SUB_PORT# LIST---"
if [ -n "$PORTS" ]; then
  echo "$PORTS"
else
  echo "(none detected via: ethctl $LAN_TRUNK media-type port N)"
fi
echo ""

if [ -z "$LAN_TRUNK" ] || [ -z "$PORTS" ] || [ -z "$ETHCTL" ]; then
  echo "Cannot do interactive mapping (missing LAN_TRUNK, PORTS, or ethctl)."
  exit 0
fi

echo "How many physical LAN jacks do you want to map? (exclude WAN)"
printf "Enter LAN jack count (e.g. 4), or press Enter for 4: "
read -r LANJ
[ -z "$LANJ" ] && LANJ=4

port_state() {
  i="$1"; p="$2"
  line="$("$ETHCTL" "$i" media-type port "$p" 2>/dev/null | grep -m1 'Link is')"
  case "$line" in
    *"Link is Up"*) echo up ;;
    *"Link is Down"*) echo down ;;
    *) echo "?" ;;
  esac
}

snapshot_ports() {
  i="$1"; ports="$2"; out="$3"
  : > "$out"
  for p in $ports; do
    echo "$p $(port_state "$i" "$p")" >> "$out"
  done
}

detect_up_since() {
  i="$1"; ports="$2"; snap="$3"
  n=0
  while [ $n -lt 25 ]; do
    for p in $ports; do
      before="$(awk -v pp="$p" '$1==pp{print $2}' "$snap" 2>/dev/null)"
      now="$(port_state "$i" "$p")"
      [ "$before" = "down" ] && [ "$now" = "up" ] && { echo "$p"; return 0; }
    done
    sleep 1
    n=$((n + 1))
  done
  return 1
}

echo ""
echo "INTERACTIVE MAPPING:"
echo "1) Unplug ALL LAN cables (WAN can stay connected)."
echo "2) Press Enter."
read -r _

snap="/tmp/portsnap.$$"
snapshot_ports "$LAN_TRUNK" "$PORTS" "$snap"

idx=1
while [ $idx -le "$LANJ" ]; do
  echo ""
  echo "Plug a cable into *physical* LAN$idx now, then press Enter."
  read -r _
  hit="$(detect_up_since "$LAN_TRUNK" "$PORTS" "$snap")"
  if [ -n "$hit" ]; then
    echo "LAN$idx -> sub_port#$hit (via $LAN_TRUNK)"
    snapshot_ports "$LAN_TRUNK" "$PORTS" "$snap"
    echo "Unplug the cable from LAN$idx before continuing."
  else
    echo "LAN$idx -> (no sub_port link-up detected)"
  fi
  idx=$((idx + 1))
done

rm -f "$snap"
