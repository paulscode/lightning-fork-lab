# Lightning Fork regtest lab.
#
#   make build           build lnd/lncli from ../lightning-fork and the dev image
#   make up              start the BLAKE2b regtest, the SHA256d regtest, lf1, lf2, lnd-sha
#   make scenarios       run every scenario in order (each is also a target)
#   make down            stop everything, keep state
#   make nuke            stop and wipe all state
#
# Helpers:
#   make b2b CMD="getblockcount"      bitcoin-cli on the BLAKE2b node
#   make sha CMD="getblockcount"      bitcoin-cli on the SHA256d node
#   make lf1 CMD="getinfo"            lncli on lf1 (also lf2, lndsha)
#   make cln / make cln-interop       Core Lightning (BLAKE2b identity) and the interop scenario
#   make all-scenarios                every scenario including cln-interop (after make cln)
#   make cln-release / cln-migration  the released privkeyio binaries, and the upgrade-path scenario
#   make cln-cli CMD="getinfo"        lightning-cli on it

SHELL := /bin/bash
COMPOSE := docker compose
FORK_DIR := $(abspath ../lightning-fork)
# The RPC subservers a release build carries; without them lncli has no
# `wallet` command and the daemon no WalletKit, which the scenarios use.
LND_TAGS ?= autopilotrpc signrpc walletrpc chainrpc invoicesrpc watchtowerrpc peersrpc routerrpc offersrpc
export GOWORK := $(FORK_DIR)/go.work
export ACTIVATION_HEIGHT ?= 20

.PHONY: build up down nuke logs b2b sha lf1 lf2 lndsha scenarios bridge-setup offer-latency cln4-split \
	e3-sync e4-isolation e4b-refuse e7-replay channel reorg restart bolt12

build:
	mkdir -p bin
	cd $(FORK_DIR) && go build -tags "$(LND_TAGS)" -o $(abspath bin/lnd) ./cmd/lnd
	cd $(FORK_DIR) && go build -tags "$(LND_TAGS)" -o $(abspath bin/lncli) ./cmd/lncli
	$(COMPOSE) build lf1

up:
	$(COMPOSE) up -d fees knots-b2b bitcoind-sha
	bash scripts/wait-chains.sh
	$(COMPOSE) up -d lf1 lf2 lnd-sha

down:
	$(COMPOSE) --profile refuse --profile cln down

nuke:
	$(COMPOSE) --profile refuse --profile cln down -v
	rm -rf results/*.log
	@echo "All lab state wiped."

logs:
	$(COMPOSE) logs -f --tail=100

b2b:
	@$(COMPOSE) exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab $(CMD)

sha:
	@$(COMPOSE) exec -T bitcoind-sha bitcoin-cli -regtest -rpcuser=lab -rpcpassword=lab -rpcconnect=127.0.0.1 -rpcport=18443 $(CMD)

lf1:
	@$(COMPOSE) exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 $(CMD)

lf2:
	@$(COMPOSE) exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 $(CMD)

lndsha:
	@$(COMPOSE) exec -T lnd-sha lncli --network=regtest --rpcserver=127.0.0.1:10009 $(CMD)

# reorg goes last: it replaces the chain from below the activation height,
# which voids every coin and channel funded before it (lnd keeps the
# channels open and the wallet keeps the coins; see the plan's note).
# bridge-setup stands up the channels a cross-chain swap needs, on both chains,
# and exports the credentials the bridge's live test connects with.
# offer-latency measures what the fetch-first payout design costs: how long a
# BOLT 12 invoice fetch takes, and the smallest payer timeout it fits inside.
offer-latency:
	@scripts/scenario-offer-latency.sh

# cln4-split asks whether Lightning Fork and privkeyio v26.06.7-blake2b.4 can
# reach each other. Same chain, and currently not the same Lightning network.
# Needs the .4 image: make cln-release CLN_RELEASE=v26.06.7-blake2b.4 with the
# tag overridden, see the script header.
cln4-split:
	@scripts/scenario-cln4-split.sh

bridge-setup:
	@scripts/bridge-setup.sh

scenarios: e3-sync e4b-refuse e4-isolation e7-replay channel restart bolt12 reorg
	@echo "ALL SCENARIOS PASSED"

# Everything, including the Core Lightning interop scenario (needs `make cln`).
all-scenarios: e3-sync e4b-refuse e4-isolation e7-replay channel restart bolt12 cln-interop reorg
	@echo "ALL SCENARIOS PASSED, WITH CORE LIGHTNING"

e3-sync:
	bash scripts/scenario-e3-sync.sh

e4-isolation:
	bash scripts/scenario-e4-isolation.sh

e4b-refuse:
	bash scripts/scenario-e4b-refuse.sh

e7-replay:
	bash scripts/scenario-e7-replay.sh

channel:
	bash scripts/scenario-channel.sh

reorg:
	bash scripts/scenario-reorg.sh

restart:
	bash scripts/scenario-restart.sh

bolt12:
	bash scripts/scenario-bolt12.sh

# Core Lightning with the BLAKE2b chain identity: the privkeyio port plus the
# patch series in the fork repository, built from source (minutes).
cln:
	rm -rf build/cln-patches && mkdir -p build/cln-patches
	cp $(FORK_DIR)/contrib/cln-chain-identity/*.patch build/cln-patches/
	id=$$(docker create knots-blake2b:final-zmq) && docker cp $$id:/usr/local/bin/bitcoin-cli build/bitcoin-cli && docker rm $$id >/dev/null
	$(COMPOSE) --profile cln build cln
	$(COMPOSE) --profile cln up -d cln

cln-interop:
	CLN_CONTAINER=lightning-fork-lab-cln-1 CLN_HOST=cln bash scripts/scenario-cln-interop.sh

# The released privkeyio binaries (Bitcoin's identity), for the upgrade-path
# scenario: downloaded from the GitHub release and checked against its sums.
CLN_RELEASE ?= v26.06.7-blake2b.3
CLN_TARBALL ?= clightning-$(CLN_RELEASE)-Ubuntu-24.04-amd64.tar.xz
cln-release:
	mkdir -p build
	id=$$(docker create knots-blake2b:final-zmq) && docker cp $$id:/usr/local/bin/bitcoin-cli build/bitcoin-cli && docker rm $$id >/dev/null
	[ -f build/$(CLN_TARBALL) ] || gh release download $(CLN_RELEASE) --repo privkeyio/lightning -p '$(CLN_TARBALL)' -p 'SHA256SUMS-$(CLN_RELEASE)' -D build
	cd build && grep '$(CLN_TARBALL)' SHA256SUMS-$(CLN_RELEASE) | sha256sum -c
	docker build -f Dockerfile.cln-release --build-arg CLN_TARBALL=$(CLN_TARBALL) -t cln-blake2b-release:lab .

cln-migration:
	bash scripts/scenario-cln-migration.sh

cln-cli:
	docker exec lightning-fork-lab-cln-1 lightning-cli --network=regtest --lightning-dir=/data $(CMD)
