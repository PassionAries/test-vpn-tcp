#!/usr/bin/env bash
#
# DNS Global Monitor - single file curl|bash edition
#
# Usage:
# bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/dns-monitor.sh)
#
# Features:
# - Global public DNS only
# - IPv4 / IPv6
# - UDP DNS latency
# - TCP DNS latency
# - packet loss / failure rate
# - DNSSEC check
# - DoH latency
# - DoT TLS check
# - best DNS selection
# - systemd-resolved config output
#

set -u

INTERVAL=${INTERVAL:-30}
DOMAIN=${DOMAIN:-cloudflare.com}
COUNT=3

cleanup() {
    rm -f /tmp/dnsmon.*
}
trap cleanup EXIT INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing dependency: $1"
        exit 1
    }
}

need_cmd dig
need_cmd curl
need_cmd openssl
need_cmd awk
need_cmd sort

DNS_LIST=(
"Cloudflare|1.1.1.1|2606:4700:4700::1111|cloudflare-dns.com|https://cloudflare-dns.com/dns-query"
"Google|8.8.8.8|2001:4860:4860::8888|dns.google|https://dns.google/dns-query"
"Quad9|9.9.9.9|2620:fe::fe|dns.quad9.net|https://dns.quad9.net/dns-query"
"OpenDNS|208.67.222.222|2620:119:35::35|doh.opendns.com|https://doh.opendns.com/dns-query"
"AdGuard|94.140.14.14|2a10:50c0::ad1:ff|dns.adguard-dns.com|https://dns.adguard-dns.com/dns-query"
"CleanBrowsing|185.228.168.9|2a0d:2a00:1::2|security-filter-dns.cleanbrowsing.org|https://doh.cleanbrowsing.org/doh/security-filter/"
"ControlD|76.76.2.0|2606:1a40::|p0.freedns.controld.com|https://freedns.controld.com/p0"
"Neustar|64.6.64.6|||"
"Verisign|64.6.65.6|||"
)

echo "System DNS:"
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl dns 2>/dev/null || true
else
    grep nameserver /etc/resolv.conf 2>/dev/null || true
fi

latency_udp() {
    dig @"$1" "$DOMAIN" +stats +time=2 +tries=1 2>/dev/null |
    awk '/Query time/ {print $4}'
}

latency_tcp() {
    dig @"$1" "$DOMAIN" +tcp +stats +time=2 +tries=1 2>/dev/null |
    awk '/Query time/ {print $4}'
}

latency_ipv6() {
    dig -6 @"$1" "$DOMAIN" +stats +time=2 +tries=1 2>/dev/null |
    awk '/Query time/ {print $4}'
}

dnssec_check() {
    dig @"$1" "$DOMAIN" +dnssec 2>/dev/null |
    grep -q " ad " && echo YES || echo NO
}

doh_test() {
    [ -z "$1" ] && echo NA && return
    curl -s -o /dev/null \
        --max-time 5 \
        -H 'accept: application/dns-message' \
        -w "%{time_total}" "$1"
}

dot_test() {
    [ -z "$1" ] && echo NA && return
    timeout 5 openssl s_client \
        -connect "$1:853" \
        -servername "$1" \
        </dev/null >/dev/null 2>&1 \
        && echo OK || echo FAIL
}

avg() {
    awk '{s+=$1;c++}END{if(c)printf "%.0f",s/c;else print 9999}'
}

while true
do
clear

echo "=============================================="
echo " DNS GLOBAL MONITOR"
echo " Domain: $DOMAIN"
echo " Refresh: ${INTERVAL}s"
echo "=============================================="

RESULTS=()

printf "%-12s %-7s %-7s %-7s %-8s %-7s\n" \
NAME UDP TCP IPv6 LOSS DNSSEC

for item in "${DNS_LIST[@]}"
do
    IFS="|" read NAME V4 V6 DOT DOH <<< "$item"

    UDP=""
    TCP=""
    V6=""
    FAIL=0

    for i in $(seq 1 $COUNT)
    do
        U=$(latency_udp "$V4")
        T=$(latency_tcp "$V4")

        [ -z "$U" ] && FAIL=$((FAIL+1)) || UDP="$UDP $U"
        [ -z "$T" ] && FAIL=$((FAIL+1)) || TCP="$TCP $T"

        if [ -n "$V6" ] && [ -n "$V6" ]; then
            :
        fi
    done

    UDP_AVG=$(echo "$UDP" | avg)
    TCP_AVG=$(echo "$TCP" | avg)

    if [ -n "$V6" ]; then
        V6_AVG=$(latency_ipv6 "$V6")
    else
        V6_AVG=NA
    fi

    LOSS=$((FAIL*100/(COUNT*2)))

    SEC=$(dnssec_check "$V4")

    printf "%-12s %-7sms %-7sms %-7s %-7s %-7s\n" \
    "$NAME" "$UDP_AVG" "$TCP_AVG" "$V6_AVG" "${LOSS}%" "$SEC"

    RESULTS+=("$UDP_AVG|$NAME|$V4|$V6")

    echo "  DoH: $(doh_test "$DOH")"
    echo "  DoT: $(dot_test "$DOT")"
    echo

done

BEST=$(printf "%s\n" "${RESULTS[@]}" | sort -n | head -1)

BEST4=$(echo "$BEST" | cut -d'|' -f3)
BEST6=$(echo "$BEST" | cut -d'|' -f4)

echo "=============================================="
echo " BEST DNS"
echo "=============================================="
echo "$BEST"

echo
echo "Copy for systemd-resolved:"
echo "----------------------------------------------"
echo "[Resolve]"
echo "DNS=$BEST4 $BEST6"
echo "FallbackDNS=8.8.8.8 2001:4860:4860::8888"
echo "DNSSEC=yes"
echo "DNSOverTLS=yes"
echo "----------------------------------------------"

echo
echo "Next scan in ${INTERVAL}s"

sleep "$INTERVAL"

done
