#!/usr/bin/env bash
# DNZ's memory use through a day's work: idle, a 10,000-record zone import,
# authoritative and cached query load, and idle again.
#
#   ./memory.sh                                 # the release image from Docker Hub
#   MEM_IMAGE=terrificci/dnz:1.5.0 ./memory.sh  # a given release
#   MEM_CPUS=4 ./memory.sh
#   MEM_BUILD=1 ./memory.sh                     # DNZ built from source (source repository only)
#
# DNZ runs from the release image with its defaults, on MEM_CPUS CPUs
# (default 2) and 1 GiB. Knot DNS from the benchmark tools image is the
# upstream; dnsperf sends the load. Memory is read from
# /proc/<dnz>/status: RSS, and of that the heap and stacks (RssAnon) and the
# mapped binary (RssFile), which the kernel can drop and read again.
set -euo pipefail
cd "$(dirname "$0")"

CPUS=${MEM_CPUS:-2}
IMAGE=${MEM_IMAGE:-terrificci/dnz:latest}
NET=dnz-memory SUBNET=172.29.53
DNZ=dnz-memory-dnz KNOT=dnz-memory-knot PERF=dnz-memory-perf

log() { printf '\033[1m%s\033[0m\n' "$*" >&2; }

if [ -n "${MEM_BUILD:-}" ]; then
    log "Building the DNZ image"
    IMAGE=dnz-memory
    docker build -q -t "$IMAGE" ../.. >/dev/null
else
    docker pull -q "$IMAGE" >/dev/null || docker image inspect "$IMAGE" >/dev/null
fi
docker compose build -q knot

# The same zones and query lists as run.sh, with this network's addresses.
mkdir -p work/memory/zones
zone() {
    printf '$ORIGIN %s.\n$TTL 3600\n' "$1"
    printf '@ SOA ns1.%s. hostmaster.%s. 1 7200 3600 1209600 300\n@ NS ns1\nns1 A %s.10\nwww CNAME host1\n' "$1" "$1" "$SUBNET"
    awk 'BEGIN { for (i = 1; i <= 10000; i++) printf "host%d A 10.%d.%d.%d\n", i, int(i / 65536) % 256, int(i / 256) % 256, i % 256 }'
}
zone bench.example >work/memory/zones/bench.example.zone
zone fwd.example >work/memory/zones/fwd.example.zone
awk 'BEGIN { for (i = 1; i <= 10000; i++) { printf "host%d.bench.example A\n", i; if (i % 9 == 0) printf "nx%d.bench.example A\n", i } }' >work/memory/auth.txt
awk 'BEGIN { for (i = 1; i <= 10000; i++) printf "host%d.fwd.example A\n", i }' >work/memory/cached.txt

cleanup() { docker rm -f "$DNZ" "$KNOT" "$PERF" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
cleanup
trap cleanup EXIT
docker network create --subnet "$SUBNET.0/24" "$NET" >/dev/null
docker run -d --name "$KNOT" --network "$NET" --ip "$SUBNET.10" -v "$PWD/conf:/bench/conf:ro" -v "$PWD/work/memory:/bench/work:ro" \
    dnz-bench-tools sh -c 'mkdir -p /tmp/knot /run/knot && exec knotd -c /bench/conf/knot.conf' >/dev/null
docker run -d --name "$PERF" --network "$NET" --ip "$SUBNET.99" --cpus 2 -v "$PWD/work/memory:/bench/work:ro" dnz-bench-tools sleep infinity >/dev/null
docker run -d --name "$DNZ" --network "$NET" --ip "$SUBNET.20" --cpus "$CPUS" -m 1g \
    -e DNZ_UPSTREAM="$SUBNET.10:53" -e DNZ_RATE_LIMIT=0 \
    -e DNZ_ADMIN_USERNAME=bench -e DNZ_ADMIN_PASSWORD=load-test-pass-1 \
    "$IMAGE" >/dev/null

perf() { docker exec "$PERF" "$@"; }
api=http://$SUBNET.20:8080/api
for _ in $(seq 1 60); do perf curl -fs "$api/health" >/dev/null && break; sleep 1; done

# One row: phase, RSS, heap and stacks, binary, threads (MB from kB).
rows=()
measure() {
    local status
    status=$(docker run --rm --pid="container:$DNZ" dnz-bench-tools cat /proc/1/status)
    rows+=("$(awk -v phase="$1" '
        /^VmRSS:/ { rss = $2 } /^RssAnon:/ { anon = $2 } /^RssFile:/ { file = $2 } /^Threads:/ { threads = $2 }
        END { printf "| %s | %.1f | %.1f | %.1f | %d |", phase, rss / 1024, anon / 1024, file / 1024, threads }' <<<"$status")")
    log "${rows[${#rows[@]}-1]}"
}
load() { perf dnsperf -s "$SUBNET.20" -d "$1" -l 20 -c 32 -q 500 -T 2 -S 0 >/dev/null 2>&1; }

log "Idle"
sleep 30
measure "Idle after start"

log "Importing bench.example (10,000 records)"
perf sh -ec "
    api=$api
    login() { curl -fs \"\$api/auth/login\" -H 'content-type: application/json' -d \"{\\\"username\\\":\\\"bench\\\",\\\"password\\\":\\\"\$1\\\"}\" | jq -r .token; }
    token=\$(login load-test-pass-1)
    curl -fs -X PUT \"\$api/auth/password\" -H \"authorization: Bearer \$token\" -H 'content-type: application/json' \
        -d '{\"current_password\":\"load-test-pass-1\",\"new_password\":\"load-test-pass-2\"}' >/dev/null
    token=\$(login load-test-pass-2)
    division=\$(curl -fs \"\$api/divisions\" -H \"authorization: Bearer \$token\" | jq '.[0].id')
    jq -n --rawfile content /bench/work/zones/bench.example.zone '{content: \$content, name: \"bench.example\", apply: true}' \
        | curl -fs -X POST \"\$api/divisions/\$division/zones/import\" -H \"authorization: Bearer \$token\" -H 'content-type: application/json' -d @- >/dev/null
"
sleep 5
measure "After the import"

log "Authoritative load"
load /bench/work/auth.txt &
sleep 15
measure "Authoritative load"
wait

log "Cached forwarding load"
perf dnsperf -s "$SUBNET.20" -d /bench/work/cached.txt -n 1 -c 4 -q 100 >/dev/null 2>&1
load /bench/work/cached.txt &
sleep 15
measure "Cached forwarding load"
wait

log "Idle again"
sleep 60
measure "Idle, a minute later"

echo "$IMAGE on $CPUS CPUs ($(docker info --format '{{.Architecture}}')):"
echo
echo "| Phase | RSS (MB) | Heap and stacks (MB) | Binary (MB) | Threads |"
echo "|---|---:|---:|---:|---:|"
printf '%s\n' "${rows[@]}"
