#!/bin/bash
# Sustained WAN quality sampler for ISP fault evidence.
# Usage: wansample.sh [samples] [interval_seconds] [outfile]
set -u
SAMPLES=${1:-15}
INTERVAL=${2:-120}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${3:-$HOME/logs/wansample-$STAMP.csv}
mkdir -p "$(dirname "$OUT")"

echo "ts,router_rtt_ms,router_loss_pct,wan_rtt_ms,wan_mdev_ms,wan_loss_pct,dl_mbps,ul_mbps,note" > "$OUT"

wan_ping() { # host count -> "avg mdev loss"
  ping -c "$2" -i 0.2 -W 2000 "$1" 2>/dev/null | awk '
    /packet loss/ { match($0, /[0-9.]+% packet loss/); loss=substr($0,RSTART,RLENGTH); gsub(/%.*/,"",loss) }
    / = / && /\// { s=substr($0, index($0,"= ")+2); n=split(s,a,"/"); avg=a[2]; mdev=a[4]; gsub(/ .*/,"",mdev); if (mdev=="nan") mdev="NA" }
    END { if (loss=="") print "NA NA 100"; else printf "%s %s %s\n", (avg==""?"NA":avg), (mdev==""?"NA":mdev), loss }'
}

dl_test() { # -> mbps or NA
  curl -s -o /dev/null --max-time 15 \
    -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=25000000&r=$RANDOM" 2>/dev/null \
    | awk '{ if ($1>0) printf "%.2f", $1*8/1000000; else print "NA" }'
}

ul_test() { # -> mbps or NA
  head -c 5000000 /dev/zero | curl -s -o /dev/null --max-time 15 -X POST \
    --data-binary @- -H 'Content-Type: application/octet-stream' \
    -w '%{speed_upload}' "https://speed.cloudflare.com/__up?r=$RANDOM" 2>/dev/null \
    | awk '{ if ($1>0) printf "%.2f", $1*8/1000000; else print "NA" }'
}

for i in $(seq 1 "$SAMPLES"); do
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  read -r R_AVG R_MDEV R_LOSS <<<"$(wan_ping 192.168.0.1 10)"
  read -r W_AVG W_MDEV W_LOSS <<<"$(wan_ping 1.1.1.1 20)"
  DL=$(dl_test)
  if [ "$W_LOSS" = "0" ] || [ "$W_LOSS" = "5" ]; then UL=$(ul_test); else UL=skip; fi
  echo "$TS,$R_AVG,$R_LOSS,$W_AVG,$W_MDEV,$W_LOSS,$DL,$UL," >> "$OUT"
  echo "[$i/$SAMPLES] $TS  wan ${W_AVG}ms/${W_MDEV}ms loss ${W_LOSS}%  dl ${DL}Mbps  ul ${UL}Mbps" >&2
  [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
done
echo "DONE $OUT" >&2
