#!/usr/bin/env bash
# Reverse proxy benchmark: dnz-proxy against nginx, HAProxy, Envoy, Caddy and
# Traefik, each forwarding to the same nginx origin, on one Docker network.
# dnz-proxy joins a DNZ that pushes its configuration, as in production; both
# come from the release image on Docker Hub (DNZ_IMAGE, default
# terrificci/dnz:latest). The others are the upstream images (versions in
# docker-compose.yml).
#
#   ./run.sh                                  # run, print a Markdown table
#   BENCH_DURATION=30 BENCH_RUNS=5 ./run.sh
#   BENCH_PROXIES="dnzproxy nginx" ./run.sh   # only these (service names)
#   BENCH_PROXY_CPUS=1,2 ./run.sh             # two CPUs for the proxy under test
#   BENCH_KEEP=1 ./run.sh                     # leave the containers running
#   DNZ_IMAGE=terrificci/dnz:1.6.1 ./run.sh   # a given release
#   BENCH_BUILD=1 ./run.sh                    # DNZ and dnz-proxy built from source (source repository only)
#
# Scenarios, each a wrk run of BENCH_DURATION seconds with BENCH_CONNECTIONS
# keep-alive connections, BENCH_RUNS times (the median counts):
#   http        GET / over HTTP/1.1, a 1 KiB answer
#   https       the same over TLS 1.3, connections kept open
#   handshake   TLS 1.3, a new connection for every request; wrk resumes the
#               TLS session (each proxy's default: all of them resume)
#   http-64k    GET /64k over HTTP/1.1, a 64 KiB answer
# Then a fixed rate (BENCH_RATE requests per second over HTTP, with hey):
# latency p50/p99 and the proxy's CPU time per request (from its cgroup), and
# its memory (anonymous, from its cgroup) idle and after the load.
#
# The proxy under test is pinned to BENCH_PROXY_CPUS (default CPU 1), the
# origin and DNZ to CPU 0, the load generators to CPUs 2-3. Results go to
# work/results.md.
set -euo pipefail
cd "$(dirname "$0")"

DURATION=${BENCH_DURATION:-20}
RUNS=${BENCH_RUNS:-3}
CONNS=${BENCH_CONNECTIONS:-64}
RATE=${BENCH_RATE:-5000}
RATE_WORKERS=50
PROXIES=${BENCH_PROXIES:-"dnzproxy nginx haproxy envoy caddy traefik"}
SCENARIOS="http https handshake http-64k"

# CPUs in a cpuset list such as "1", "1,2" or "1-3".
ncpu() { echo "$1" | tr ',' '\n' | awk -F- '{ n += (NF == 2 ? $2 - $1 + 1 : 1) } END { print n }'; }
export BENCH_PROXY_NCPU=$(ncpu "${BENCH_PROXY_CPUS:-1}")

ip() {
    case $1 in
        dnzproxy) echo 172.28.54.30 ;; nginx) echo 172.28.54.31 ;; haproxy) echo 172.28.54.32 ;;
        envoy) echo 172.28.54.33 ;; caddy) echo 172.28.54.34 ;; traefik) echo 172.28.54.35 ;;
    esac
}
label() {
    case $1 in
        dnzproxy) echo dnz-proxy ;; nginx) echo nginx ;; haproxy) echo HAProxy ;;
        envoy) echo Envoy ;; caddy) echo Caddy ;; traefik) echo Traefik ;;
    esac
}

dc() { docker compose "$@"; }
perf() { dc exec -T perf "$@"; }
log() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
median() { sort -g | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)]; else print 0 }'; }

cgroup() { echo "/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "$(dc ps -q "$1")").scope"; }
anon_mib() { awk '$1 == "anon" { printf "%.0f", $2 / 1048576 }' "$(cgroup "$1")/memory.stat"; }
cpu_usec() { awk '$1 == "usage_usec" { print $2 }' "$(cgroup "$1")/cpu.stat"; }

teardown() { [ -n "${BENCH_KEEP:-}" ] || dc down -v --remove-orphans >/dev/null 2>&1 || true; }
trap teardown EXIT

# --- Content and certificate -----------------------------------------------------
log "Building the images"
if [ -n "${BENCH_BUILD:-}" ]; then
    docker build -q -t dnz-proxybench-dnz -f Dockerfile.dnz ../.. >/dev/null
    export DNZ_IMAGE=dnz-proxybench-dnz
else
    export DNZ_IMAGE=${DNZ_IMAGE:-terrificci/dnz:latest}
    # A newer one if there is, else the one already here.
    docker pull -q "$DNZ_IMAGE" >/dev/null || docker image inspect "$DNZ_IMAGE" >/dev/null
fi
dc build perf
mkdir -p work/www work/tls work/raw
head -c 1024 /dev/zero | tr '\0' 'a' >work/www/1k.html
head -c 65536 /dev/zero | tr '\0' 'b' >work/www/64k.html
dc up -d backend perf
if [ ! -s work/tls/cert.pem ]; then
    log "Making an ECDSA P-256 certificate for app.bench.test"
    perf openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
        -subj /CN=app.bench.test -addext subjectAltName=DNS:app.bench.test \
        -keyout /bench/work/tls/key.pem -out /bench/work/tls/cert.pem 2>/dev/null
fi
# Written as root in the container; the proxies run as other users.
perf sh -c 'cd /bench/work/tls && cat cert.pem key.pem >haproxy.pem && chmod 644 *.pem'


# --- dnz-proxy: DNZ, a proxy, a route and a node ----------------------------------
API=http://172.28.54.20:8080/api
api() {
    local body=()
    [ $# -lt 3 ] || body=(--data-binary "$3")
    local out
    if ! out=$(perf curl -sS --fail-with-body -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X "$1" "$API$2" "${body[@]}"); then
        log "$1 $2: $out"
        return 1
    fi
    echo "$out"
}

setup_dnz() {
    dc up -d dnz
    local i
    for i in $(seq 60); do
        perf curl -sf -o /dev/null "$API/health" && break
        sleep 1
    done
    TOKEN=$(perf curl -sS --fail-with-body -H 'Content-Type: application/json' -d '{"username":"bench","password":"load-test-pass-1"}' "$API/auth/login" | jq -r .token)
    # The admin made from the environment has to pick a password of its own first.
    api PUT /auth/password '{"current_password":"load-test-pass-1","new_password":"load-test-pass-2"}' >/dev/null
    # Routers take names in DNZ's own zones.
    local division
    division=$(api GET /divisions | jq -r 'if type == "array" then .[0].id else .divisions[0].id end')
    api POST "/divisions/$division/zones" '{"name":"bench.test"}' >/dev/null
    local proxy
    proxy=$(api POST /proxies '{"name":"bench","kind":"dnz","ipv4":"172.28.54.30"}' | jq -r .id)
    api POST /proxy/dnz/nodes "{\"proxy_id\":$proxy,\"name\":\"node1\",\"public_ipv4\":\"172.28.54.30\"}" >/dev/null
    local service
    service=$(api POST "/proxies/$proxy/services" '{"name":"app","servers":[{"url":"http://172.28.54.10:80","weight":1}],"pass_host_header":true,"skip_tls_verify":false,"health_check_path":"","health_check_interval_secs":10,"strategy":"wrr","sticky":false,"sticky_cookie":"","kind":"loadBalancer","options":{}}' | jq -r .id)
    api POST "/proxies/$proxy/routers" "{\"name\":\"app\",\"hosts\":[\"app.bench.test\"],\"entry_points\":[\"web\"],\"service_id\":$service}" >/dev/null
    api POST "/proxies/$proxy/routers" "{\"name\":\"app-tls\",\"hosts\":[\"app.bench.test\"],\"entry_points\":[\"websecure\"],\"tls\":true,\"service_id\":$service}" >/dev/null
    local cert
    cert=$(perf jq -cn --rawfile c /bench/work/tls/cert.pem --rawfile k /bench/work/tls/key.pem '{kind: "certificate", name: "bench", config: {certFile: $c, keyFile: $k}}')
    api POST "/proxies/$proxy/objects" "$cert" >/dev/null
    api POST "/proxies/$proxy/objects" '{"kind":"tlsStore","name":"default","config":{"defaultCertificate":"bench"}}' >/dev/null
    DNZ_PROXY_KEY=$(api GET /settings/proxy | jq -r .connect_key)
    export DNZ_PROXY_KEY
}

# --- Runs ------------------------------------------------------------------------
# wrk's latency lines ("99%  12.34ms") in milliseconds.
wrk_ms() { awk -v p="$1" '$1 == p { v = $2; u = v; sub(/[0-9.]+/, "", u); sub(/[a-z]+$/, "", v); m = (u == "us" ? 0.001 : u == "s" ? 1000 : 1); printf "%.2f\n", v * m }' "$2"; }

url() {
    case $1 in
        http) echo http://app.bench.test/ ;; https | handshake) echo https://app.bench.test/ ;;
        http-64k) echo http://app.bench.test/64k ;;
    esac
}

wait_ready() {
    local i
    for i in $(seq 90); do
        if perf curl -sfk -o /dev/null https://app.bench.test/ && perf curl -sf -o /dev/null http://app.bench.test/64k; then
            return 0
        fi
        sleep 1
    done
    log "$1 didn't answer on http://app.bench.test/64k and https://app.bench.test/"
    dc logs --tail 40 "$1" >&2
    return 1
}

: >work/raw/summary.tsv
for p in $PROXIES; do
    log "== $(label "$p")"
    if [ "$p" = dnzproxy ]; then setup_dnz; fi
    dc up -d "$p"
    # app.bench.test points at the proxy under test, so TLS gets the right SNI.
    perf sh -c "grep -v app.bench.test /etc/hosts >/tmp/hosts; echo '$(ip "$p") app.bench.test' >>/tmp/hosts; cat /tmp/hosts >/etc/hosts"
    wait_ready "$p"
    # The answer must be the origin's, through the proxy.
    size=$(perf curl -s -o /dev/null -w '%{size_download}' http://app.bench.test/64k)
    [ "$size" = 65536 ] || { log "$p: /64k answered $size bytes"; exit 1; }
    # wrk resumes TLS sessions; say whether this proxy lets it.
    resumed=$(perf sh -c 'sleep 1 | openssl s_client -connect app.bench.test:443 -servername app.bench.test -sess_out /tmp/sess >/dev/null 2>&1; sleep 1 | openssl s_client -connect app.bench.test:443 -servername app.bench.test -sess_in /tmp/sess 2>/dev/null | grep -c "^Reused"' || true)
    log "  TLS session resumed: $([ "$resumed" -gt 0 ] && echo yes || echo no)"
    sleep 3
    idle=$(anon_mib "$p")

    row="$p	$idle"
    for s in $SCENARIOS; do
        extra=()
        [ "$s" = handshake ] && extra=(-H 'Connection: close')
        for r in $(seq "$RUNS"); do
            out=work/raw/$p-$s-$r.txt
            perf wrk -t2 -c"$CONNS" -d"${DURATION}s" --latency "${extra[@]}" "$(url "$s")" >"$out"
            errs=$(awk '/Non-2xx|Socket errors/' "$out")
            [ -z "$errs" ] || log "  $s run $r: $errs"
        done
        rps=$(for r in $(seq "$RUNS"); do awk '/^Requests\/sec/ { print $2 }' "work/raw/$p-$s-$r.txt"; done | median)
        p99=$(for r in $(seq "$RUNS"); do wrk_ms 99% "work/raw/$p-$s-$r.txt"; done | median)
        log "  $s: $(printf '%.0f' "$rps") req/s, p99 ${p99} ms"
        row="$row	$rps	$p99"
    done

    # Fixed rate: latency without saturation, and CPU per request. hey's
    # workers each hold RATE/RATE_WORKERS requests a second.
    before=$(cpu_usec "$p")
    perf hey -z "${DURATION}s" -c "$RATE_WORKERS" -q $((RATE / RATE_WORKERS)) http://app.bench.test/ >work/raw/$p-rate.txt
    after=$(cpu_usec "$p")
    loaded=$(anon_mib "$p")
    done_reqs=$(awk '/responses$/ { n += $2 } END { print n + 0 }' work/raw/$p-rate.txt)
    ok=$(awk '$1 == "[200]" { print $2 }' work/raw/$p-rate.txt)
    p50=$(awk '$1 == "50%" { printf "%.2f", $3 * 1000 }' work/raw/$p-rate.txt)
    rp99=$(awk '$1 == "99%" { printf "%.2f", $3 * 1000 }' work/raw/$p-rate.txt)
    cpu=$(awk -v a="$before" -v b="$after" -v n="$done_reqs" 'BEGIN { printf "%.1f", n ? (b - a) / n : 0 }')
    [ "${ok:-0}" = "$done_reqs" ] || log "  rate: only ${ok:-0} of $done_reqs answered 200"
    log "  rate $RATE/s: p50 $p50 ms, p99 $rp99 ms, $cpu µs CPU/request, memory $idle → $loaded MiB"
    row="$row	$p50	$rp99	$cpu	$loaded"
    echo "$row" >>work/raw/summary.tsv

    dc rm -sf "$p" >/dev/null
    if [ "$p" = dnzproxy ]; then dc rm -sf dnz >/dev/null; fi
done

# --- Table -----------------------------------------------------------------------
{
    echo "Requests per second (median of $RUNS runs of ${DURATION}s, $CONNS connections; p99 latency in ms)"
    echo "and a fixed $RATE requests per second over HTTP. Proxy pinned to $BENCH_PROXY_NCPU CPU(s)."
    echo
    echo "| Proxy | HTTP 1 KiB | HTTPS 1 KiB | HTTPS, new connection per request | HTTP 64 KiB | p50 / p99 at $RATE/s | CPU per request | Memory idle / loaded |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|"
    while IFS='	' read -r p idle hr hp sr sp kr kp lr lp p50 rp99 cpu loaded; do
        printf '| %s | %.0f (%s ms) | %.0f (%s ms) | %.0f (%s ms) | %.0f (%s ms) | %.2f / %.2f ms | %s µs | %s / %s MiB |\n' \
            "$(label "$p")" "$hr" "$hp" "$sr" "$sp" "$kr" "$kp" "$lr" "$lp" "$p50" "$rp99" "$cpu" "$idle" "$loaded"
    done <work/raw/summary.tsv
    echo
    if [ -n "${BENCH_BUILD:-}" ]; then
        echo "Versions: DNZ and dnz-proxy $(git -C ../.. describe --always --dirty 2>/dev/null || echo '?'),"
    else
        echo "Versions: DNZ and dnz-proxy $DNZ_IMAGE ($(docker run --rm --entrypoint /usr/local/bin/dnz-proxy "$DNZ_IMAGE" --version 2>/dev/null || echo '?')),"
    fi
    tag() { dc config --images 2>/dev/null | grep "^$1:" | head -1 | cut -d: -f2 | sed -e 's/^v//' -e 's/^distroless-v//'; }
    echo "nginx $(tag nginx), HAProxy $(tag haproxy), Envoy $(tag envoyproxy/envoy), Caddy $(tag caddy), Traefik $(tag traefik);"
    echo "the origin is nginx $(tag nginx) on its own CPU; load from wrk and hey (Debian 13)."
} >work/results.md
cat work/results.md
