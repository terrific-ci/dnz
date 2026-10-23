#!/usr/bin/env bash
# DNS benchmark: DNZ against the other DNS servers people run (Knot DNS,
# Unbound, Knot Resolver, CoreDNS, BIND 9, Technitium, NSD, PowerDNS, YADIFA,
# gdnsd, Hickory DNS, dnsmasq, dnsdist, AdGuard Home, Pi-hole, Blocky),
# measured with dnsperf on one Docker network. DNZ is the release image from
# Docker Hub (DNZ_IMAGE, default terrificci/dnz:latest).
#
#   ./run.sh                                 # run, print a Markdown table
#   DNZ_IMAGE=terrificci/dnz:1.5.0 ./run.sh  # a given release
#   BENCH_DURATION=60 BENCH_RUNS=5 ./run.sh
#   BENCH_KEEP=1 ./run.sh                    # leave the containers running
#   BENCH_SERVERS="dnz nsd" ./run.sh         # only these (service names)
#   BENCH_BUILD=1 ./run.sh                   # DNZ built from source (source repository only)
#
# Two scenarios:
#   authoritative  answers from a local zone of BENCH_HOSTS names (10% of the
#                  queries are for names that don't exist).
#   cached         forwarded names, every one already in the cache (one
#                  warm-up pass first).
# AUTH and CACHED below list the servers in each.
# Each server gets BENCH_CPUS CPUs (default 2) and 1 GiB; dnsperf gets
# BENCH_PERF_CPUS (default 2). The memory column is each server's usage (docker
# stats) right after its runs. Results go to work/results.md.
set -euo pipefail
cd "$(dirname "$0")"

DURATION=${BENCH_DURATION:-20}
RUNS=${BENCH_RUNS:-3}
HOSTS=${BENCH_HOSTS:-10000}
CLIENTS=${BENCH_CLIENTS:-32}
OUTSTANDING=${BENCH_OUTSTANDING:-500}

AUTH="dnz knot unbound coredns bind technitium nsd pdns yadifa gdnsd hickory"
CACHED="dnz unbound kresd coredns bind technitium recursor dnsmasq dnsdist adguard pihole blocky hickory"
if [ -n "${BENCH_SERVERS:-}" ]; then
    only() { local out=""; for s in $1; do case " $BENCH_SERVERS " in *" $s "*) out="$out $s" ;; esac; done; echo $out; }
    AUTH=$(only "$AUTH") CACHED=$(only "$CACHED")
fi

# (No associative arrays: macOS still ships bash 3.2.)
ip() {
    case $1 in
        knot) echo 172.28.53.10 ;; dnz) echo 172.28.53.20 ;; unbound) echo 172.28.53.30 ;;
        kresd) echo 172.28.53.40 ;; coredns) echo 172.28.53.50 ;; bind) echo 172.28.53.60 ;;
        technitium) echo 172.28.53.70 ;; nsd) echo 172.28.53.80 ;; pdns) echo 172.28.53.81 ;;
        yadifa) echo 172.28.53.82 ;; gdnsd) echo 172.28.53.83 ;; hickory) echo 172.28.53.84 ;;
        recursor) echo 172.28.53.90 ;; dnsmasq) echo 172.28.53.91 ;; dnsdist) echo 172.28.53.92 ;;
        adguard) echo 172.28.53.93 ;; pihole) echo 172.28.53.94 ;; blocky) echo 172.28.53.95 ;;
    esac
}
label() {
    case $1 in
        knot) echo "Knot DNS" ;; dnz) echo DNZ ;; unbound) echo Unbound ;; kresd) echo "Knot Resolver" ;; coredns) echo CoreDNS ;;
        bind) echo "BIND 9" ;; technitium) echo Technitium ;; nsd) echo NSD ;; pdns) echo "PowerDNS Authoritative" ;;
        yadifa) echo YADIFA ;; gdnsd) echo gdnsd ;; hickory) echo "Hickory DNS" ;; recursor) echo "PowerDNS Recursor" ;;
        dnsmasq) echo dnsmasq ;; dnsdist) echo "dnsdist (packet cache)" ;; adguard) echo "AdGuard Home" ;;
        pihole) echo Pi-hole ;; blocky) echo Blocky ;;
    esac
}

perf() { docker compose exec -T perf "$@"; }
log() { printf '\033[1m%s\033[0m\n' "$*" >&2; }

# --- Zones and query files -------------------------------------------------------
log "Writing zones and queries ($HOSTS names each)"
mkdir -p work/zones
zone() {
    local origin=$1
    printf '$ORIGIN %s.\n$TTL 3600\n' "$origin"
    printf '@ SOA ns1.%s. hostmaster.%s. 1 7200 3600 1209600 300\n@ NS ns1\nns1 A 172.28.53.10\nwww CNAME host1\n' "$origin" "$origin"
    awk -v n="$HOSTS" 'BEGIN { for (i = 1; i <= n; i++) printf "host%d A 10.%d.%d.%d\n", i, int(i / 65536) % 256, int(i / 256) % 256, i % 256 }'
}
zone bench.example >work/zones/bench.example.zone
zone fwd.example >work/zones/fwd.example.zone
# Authoritative: existing names, every tenth query for one that doesn't exist.
awk -v n="$HOSTS" 'BEGIN { for (i = 1; i <= n; i++) { printf "host%d.bench.example A\n", i; if (i % 9 == 0) printf "nx%d.bench.example A\n", i } }' >work/auth.txt
awk -v n="$HOSTS" 'BEGIN { for (i = 1; i <= n; i++) printf "host%d.fwd.example A\n", i }' >work/cached.txt

# --- Servers ---------------------------------------------------------------------
log "Building and starting the servers"
if [ -n "${BENCH_BUILD:-}" ]; then
    docker build -q -t dnz-bench-dnz -f Dockerfile.dnz ../.. >/dev/null
    export DNZ_IMAGE=dnz-bench-dnz
else
    export DNZ_IMAGE=${DNZ_IMAGE:-terrificci/dnz:latest}
    case " $AUTH $CACHED " in *" dnz "*)
        # A newer one if there is, else the one already here.
        docker pull -q "$DNZ_IMAGE" >/dev/null || docker image inspect "$DNZ_IMAGE" >/dev/null ;;
    esac
fi
docker compose build
# shellcheck disable=SC2086 # word lists
docker compose up -d --force-recreate knot perf $(printf '%s\n' $AUTH $CACHED | sort -u)

wait_for() {
    local name=$1 qname=$2
    for _ in $(seq 1 180); do
        if perf kdig +short +time=1 +retry=0 "@$(ip "$name")" "$qname" A 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
    done
    echo "$(label "$name") did not answer $qname" >&2
    docker compose logs "$name" | tail -20 >&2
    exit 1
}

wait_for knot host1.bench.example
has() { case " $AUTH $CACHED " in *" $1 "*) return 0 ;; esac; return 1; }

# DNZ: its zone goes in through the API, like a user would import it.
if has dnz; then
log "Importing bench.example into DNZ"
for _ in $(seq 1 60); do perf curl -fs http://172.28.53.20:8080/api/health >/dev/null && break; sleep 1; done
perf sh -ec '
    api=http://172.28.53.20:8080/api
    login() { curl -fs "$api/auth/login" -H "content-type: application/json" -d "{\"username\":\"bench\",\"password\":\"$1\"}" | jq -r .token; }
    token=$(login load-test-pass-1 || login load-test-pass-2)
    curl -fs -X PUT "$api/auth/password" -H "authorization: Bearer $token" -H "content-type: application/json" \
        -d "{\"current_password\":\"load-test-pass-1\",\"new_password\":\"load-test-pass-2\"}" >/dev/null || true
    token=$(login load-test-pass-2)
    division=$(curl -fs "$api/divisions" -H "authorization: Bearer $token" | jq ".[0].id")
    jq -n --rawfile content /bench/work/zones/bench.example.zone "{content: \$content, name: \"bench.example\", apply: true}" \
        | curl -fs -X POST "$api/divisions/$division/zones/import" -H "authorization: Bearer $token" -H "content-type: application/json" -d @- >/dev/null
'
fi

# Technitium: settings and the zone through its API too. Its defaults limit
# each client address to 600 queries a minute; that goes, like DNZ's rate limit.
if has technitium; then
log "Configuring Technitium and importing bench.example"
for _ in $(seq 1 60); do perf curl -fs -o /dev/null http://172.28.53.70:5380/ && break; sleep 1; done
perf sh -ec '
    api=http://172.28.53.70:5380/api
    ok() { r=$(cat); echo "$r" | jq -e ".status == \"ok\"" >/dev/null || { echo "Technitium: $r" >&2; exit 1; }; }
    token=$(curl -fs "$api/user/login?user=admin&pass=load-test-pass-1" | jq -r .token)
    auth="authorization: Bearer $token"
    curl -fs -H "$auth" "$api/settings/set?recursion=Allow&forwarders=172.28.53.10&forwarderProtocol=Udp&dnssecValidation=false&qpmPrefixLimitsIPv4=false&qpmPrefixLimitsIPv6=false&cacheMaximumEntries=100000" | ok
    curl -fs -H "$auth" "$api/zones/create?zone=bench.example&type=Primary" | ok
    curl -fs -X POST -H "$auth" -H "content-type: text/plain" --data-binary @/bench/work/zones/bench.example.zone \
        "$api/zones/import?zone=bench.example&overwrite=true" | ok
'
fi
for s in $AUTH; do wait_for "$s" host1.bench.example; done
for s in $CACHED; do wait_for "$s" host1.fwd.example; done

# --- Measuring -------------------------------------------------------------------
# One dnsperf run: "qps avg_ms p_lost".
measure() {
    local ip=$1 file=$2
    perf dnsperf -s "$ip" -d "$file" -l "$DURATION" -c "$CLIENTS" -q "$OUTSTANDING" -T 2 -S 0 2>&1 | awk '
        /Queries sent:/ { sent = $3 }
        /Queries lost:/ { lost = $3 }
        /Queries per second:/ { qps = $4 }
        /Average Latency/ { avg = $4 * 1000 }
        END { printf "%.0f %.2f %.2f\n", qps, avg, sent ? lost * 100 / sent : 100 }'
}

# The median run (by queries per second) of RUNS.
median() {
    local ip=$1 file=$2 runs=()
    for _ in $(seq 1 "$RUNS"); do runs+=("$(measure "$ip" "$file")"); done
    printf '%s\n' "${runs[@]}" | sort -n | sed -n "$(((RUNS + 1) / 2))p"
}

results=work/results.md
{
    echo "Run $(date -u +%Y-%m-%dT%H:%MZ) on $(docker info --format '{{.OperatingSystem}}, {{.NCPU}} CPUs, {{.Architecture}}'):"
    echo "${BENCH_CPUS:-2} CPUs and 1 GiB per server, dnsperf on ${BENCH_PERF_CPUS:-2} CPUs, $CLIENTS clients, $OUTSTANDING queries outstanding,"
    echo "median of $RUNS runs of ${DURATION}s."
    echo
    echo "| Scenario | Server | Queries/s | Avg latency | Lost | Memory |"
    echo "|---|---|---:|---:|---:|---:|"
} >"$results"

# Memory the server's container uses now (docker stats, without the page cache).
memory() { docker stats --no-stream --format '{{.MemUsage}}' "$(docker compose ps -q "$1")" | cut -d' ' -f1; }

row() {
    local scenario=$1 server=$2 qps avg lost
    read -r qps avg lost <<<"$3"
    printf '| %s | %s | %s | %s ms | %s%% | %s |\n' "$scenario" "$(label "$server")" "$qps" "$avg" "$lost" "$(memory "$server")" >>"$results"
}

for s in $AUTH; do
    log "Authoritative: $(label "$s")"
    row Authoritative "$s" "$(median "$(ip "$s")" /bench/work/auth.txt)"
done
for s in $CACHED; do
    log "Cached forwarding: $(label "$s") (warming the cache)"
    perf dnsperf -s "$(ip "$s")" -d /bench/work/cached.txt -n 1 -c 4 -q 100 >/dev/null 2>&1
    row "Cached forwarding" "$s" "$(median "$(ip "$s")" /bench/work/cached.txt)"
done

# Versions, for the record.
{
    echo
    if [ -n "${BENCH_BUILD:-}" ]; then
        echo "Versions: DNZ $(git -C ../.. describe --always --dirty 2>/dev/null || echo '?'),"
    else
        echo "Versions: DNZ $DNZ_IMAGE,"
    fi
    echo "$(perf sh -c 'v() { dpkg-query -W -f="\${Version}" "$1" | cut -d- -f1 | sed "s/^[0-9]*://"; }; echo "Knot DNS $(v knot), Unbound $(v unbound), Knot Resolver $(v knot-resolver), BIND $(v bind9), NSD $(v nsd),"; echo "PowerDNS Authoritative $(v pdns-server), PowerDNS Recursor $(v pdns-recursor), dnsdist $(v dnsdist), YADIFA $(v yadifa),"; echo "gdnsd $(v gdnsd), dnsmasq $(v dnsmasq-base), dnsperf $(v dnsperf)"'),"
    echo "CoreDNS $(docker compose exec -T coredns /coredns -version 2>/dev/null | head -1 | cut -d- -f2 || echo 1.12.1),"
    tag() { docker compose config --images 2>/dev/null | grep "^$1:" | cut -d: -f2 | sed 's/^v//'; }
    echo "Technitium $(tag technitium/dns-server), AdGuard Home $(tag adguard/adguardhome), Pi-hole $(tag pihole/pihole),"
    echo "Blocky $(tag spx01/blocky), Hickory DNS $(sed -n 's/^ARG HICKORY_VERSION=//p' Dockerfile.hickory)."
} >>"$results"

cat "$results"
if [ -z "${BENCH_KEEP:-}" ]; then
    docker compose down -v >/dev/null 2>&1
fi
