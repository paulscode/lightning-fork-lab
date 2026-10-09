#!/usr/bin/env bash
# Lightning Fork on Umbrel answers only Umbrel's proxy.
#
# Every Umbrel app shares one Docker network, and neither the tile's front door
# (the status container) nor the dashboard has a sign-in of its own. This runs
# the store's real docker-compose.yml on a network of its own, with a container
# standing in for another app, and checks who gets in:
#
#   umbrelOS 2: umbreld proxies from the host, the network's gateway. The host
#   (this machine, here) gets through; the other app gets 403 from the front
#   door and from the dashboard, for the API, the page and the widgets.
#   umbrelOS 1: an app_proxy container proxies instead. It is let in once it
#   exists, by its container name, and its address is dropped again when it
#   goes away.
#
#   STORE_DIR        the store's app directory (~/workspace/umbrel-store/paulscode-lightning-fork)
#   DASHBOARD_IMAGE  the dashboard image to run (umbrel-lightning-fork:exposure)
#
# Uses its own compose project, network (10.66.0.0/16) and scratch directory,
# and removes them at the end.
set -euo pipefail

STORE_DIR=${STORE_DIR:-$HOME/workspace/umbrel-store/paulscode-lightning-fork}
DASHBOARD_IMAGE=${DASHBOARD_IMAGE:-umbrel-lightning-fork:exposure}
PROJECT=lfexposure
WORK=$(mktemp -d)

export APP_ID=$PROJECT
export APP_DATA_DIR=$WORK/app
export TOR_DATA_DIR=$WORK/tor
export APP_LIGHTNING_FORK_IP=10.66.22.66
export APP_LIGHTNING_FORK_STATUS_IP=10.66.22.67
export APP_LIGHTNING_FORK_NODE_IP=10.66.21.66
export APP_LIGHTNING_FORK_SHA256_IP=10.66.21.68
export APP_LIGHTNING_FORK_STATUS_DIR=$WORK/status
export APP_LIGHTNING_FORK_NODE_DATA_DIR=$WORK/lnd
export APP_LIGHTNING_FORK_MOBILE_PORT=17157
export APP_LIGHTNING_FORK_NODE_PORT=19737 APP_LIGHTNING_FORK_NODE_GRPC_PORT=20010
export APP_LIGHTNING_FORK_NODE_REST_PORT=18180 APP_LIGHTNING_FORK_WATCHTOWER_PORT=19913
export APP_LIGHTNING_FORK_COMMAND=true DEVICE_DOMAIN_NAME=lfexposure.local
export TOR_PROXY_IP=10.66.0.250 TOR_PROXY_PORT=9050 TOR_PASSWORD=x
export APP_BITCOIN_NODE_IP=10.66.0.251 APP_BITCOIN_RPC_PORT=8332
export APP_BITCOIN_RPC_USER=x APP_BITCOIN_RPC_PASS=x
export APP_LIGHTNING_FORK_REST_HIDDEN_SERVICE= APP_LIGHTNING_FORK_GRPC_HIDDEN_SERVICE=
mkdir -p "$APP_DATA_DIR/data/lightning" "$TOR_DATA_DIR/app-$APP_ID-mobile" \
	"$APP_LIGHTNING_FORK_STATUS_DIR" "$APP_LIGHTNING_FORK_NODE_DATA_DIR"

# What umbreld adds: the shared network, and (umbrelOS 1) the app_proxy
# service's image. app_proxy here is a plain nginx passing everything to
# APP_HOST:APP_PORT, without Umbrel's sign-in; the intruder is any other app.
cat >"$WORK/umbrel.yml" <<EOF
networks:
  default:
    name: ${PROJECT}_main
    ipam:
      config:
        - subnet: 10.66.0.0/16
          gateway: 10.66.0.1
services:
  app:
    image: $DASHBOARD_IMAGE
    container_name: ${APP_ID}_app_1
  status:
    container_name: ${APP_ID}_status_1
  app_proxy:
    image: nginx:1.28-alpine
    container_name: ${APP_ID}_app_proxy_1
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        printf 'server { listen 80; location / { proxy_pass http://%s:%s; } }\n' "\$\$APP_HOST" "\$\$APP_PORT" > /etc/nginx/conf.d/default.conf
        exec nginx -g 'daemon off;'
    profiles: [umbrelos1]
  intruder:
    image: curlimages/curl:8.11.1
    entrypoint: ["sleep", "infinity"]
    networks:
      default:
        ipv4_address: 10.66.30.30
EOF

COMPOSE="docker compose -p $PROJECT -f $STORE_DIR/docker-compose.yml -f $WORK/umbrel.yml"
cleanup() {
	$COMPOSE --profile umbrelos1 down -v --remove-orphans >/dev/null 2>&1 || true
	docker run --rm -v "$WORK:/w" alpine:3.20 rm -rf /w/app /w/lnd /w/status /w/tor >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The HTTP status of a GET (or POST) from the host or from the intruder.
code_host() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" || true; }
code_intruder() { $COMPOSE exec -T intruder curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" || true; }

$COMPOSE up -d status app intruder >/dev/null 2>&1
for _ in $(seq 60); do
	[ "$(code_host "http://$APP_LIGHTNING_FORK_STATUS_IP/ping")" = 200 ] && break
	sleep 1
done
[ "$(code_host "http://$APP_LIGHTNING_FORK_STATUS_IP/ping")" = 200 ] || fail "the front door never answered the host"

echo "== umbrelOS 2: umbreld proxies from the host"
c=$(code_host "http://$APP_LIGHTNING_FORK_STATUS_IP/")
[ "$c" = 200 ] || fail "the host through the front door: $c"
c=$(code_host "http://$APP_LIGHTNING_FORK_STATUS_IP/v1/system/get-update-status")
[ "$c" != 403 ] || fail "the host was refused the API through the front door"
pass "the host reaches the page and the API through the front door"

for url in "http://$APP_LIGHTNING_FORK_STATUS_IP/" \
	"http://$APP_LIGHTNING_FORK_STATUS_IP/v1/lnd/info/status" \
	"http://$APP_LIGHTNING_FORK_IP:3006/" \
	"http://$APP_LIGHTNING_FORK_IP:3006/v1/lnd/info/status" \
	"http://$APP_LIGHTNING_FORK_IP:3006/v1/lnd/widgets/lightning-wallet"; do
	c=$(code_intruder "$url")
	[ "$c" = 403 ] || fail "another app got $c from $url"
done
c=$($COMPOSE exec -T intruder curl -s -m 5 -o /dev/null -w '%{http_code}' \
	-H 'content-type: application/json' -d '{}' \
	"http://$APP_LIGHTNING_FORK_IP:3006/v1/lnd/wallet/create" || true)
[ "$c" = 403 ] || fail "another app got $c creating a wallet"
pass "another app is refused by the front door and by the dashboard"

c=$(code_host "http://$APP_LIGHTNING_FORK_IP:3006/v1/lnd/widgets/lightning-wallet")
[ "$c" != 403 ] || fail "umbreld (the host) was refused the widgets"
c=$(code_host "http://$APP_LIGHTNING_FORK_IP:3006/v1/lnd/info/status")
[ "$c" = 403 ] || fail "the host reached the dashboard's API around the front door: $c"
pass "the host reads the widgets directly, and nothing else"

echo "== umbrelOS 1: an app_proxy container proxies"
$COMPOSE --profile umbrelos1 up -d app_proxy >/dev/null 2>&1
proxy_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${APP_ID}_app_proxy_1")
for _ in $(seq 20); do
	$COMPOSE exec -T status grep -q "allow $proxy_ip;" /etc/nginx/allow.conf && break
	sleep 1
done
c=$(code_intruder "http://$proxy_ip/")
[ "$c" = 200 ] || fail "through app_proxy at $proxy_ip: $c"
pass "app_proxy at $proxy_ip is let in once it exists"

$COMPOSE --profile umbrelos1 stop app_proxy >/dev/null 2>&1
$COMPOSE --profile umbrelos1 rm -f app_proxy >/dev/null 2>&1
for _ in $(seq 20); do
	$COMPOSE exec -T status grep -q "allow $proxy_ip;" /etc/nginx/allow.conf || break
	sleep 1
done
! $COMPOSE exec -T status grep -q "allow $proxy_ip;" /etc/nginx/allow.conf ||
	fail "app_proxy's old address $proxy_ip is still let in"
pass "its address is dropped when it goes away"

echo "ALL PASS"
