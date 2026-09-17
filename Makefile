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

.PHONY: build up down nuke logs b2b sha lf1 lf2 lndsha scenarios bridge-setup offer-latency cln4-split cln-pytest \
	e3-sync e4-isolation e4b-refuse e7-replay channel reorg restart bolt12 \
	identity chain-separation prefix-offers named-channel-type gossip-height \
	unified-sigs restamp htlc-sighash cln-vanilla

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
cln-pytest:
	docker build -f Dockerfile.cln-pytest -t cln-pytest:lab .
	docker run --rm --entrypoint python3 cln-pytest:lab -m pytest -q \
		--timeout=600 -p no:cacheprovider $(PYTEST_ARGS)

cln4-split:
	@scripts/scenario-cln4-split.sh

bridge-setup:
	@scripts/bridge-setup.sh

# The bridge running inside Lightning Fork rather than as a separate daemon.
# Needs bridge-setup and pace-blocks first, and lf1 up with the bridge overlay.
bridge:
	@scripts/scenario-bridge.sh

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

# The chain-identity scenarios. These guard claims that are made publicly, in
# docs/blake2b-chain-identity.md and on the two upstream PRs, so they are worth
# running as a set rather than by hand when something nearby changes. Ordered
# cheapest first; the whole set is roughly an hour, most of it in htlc-sighash,
# which mines several hundred blocks waiting for HTLC timeouts.
#
# cln-vanilla is a prerequisite for all but chain-separation and
# named-channel-type: it is privkeyio's build with nothing of ours applied,
# which is the only thing that makes "their node computed this" checkable.
identity: chain-separation prefix-offers named-channel-type gossip-height \
	unified-sigs restamp htlc-sighash
	@echo "ALL CHAIN-IDENTITY SCENARIOS PASSED"

# option_blake2b, bit 68, is the only thing separating the two chains at init
# now that chain_hash is shared. About two minutes.
chain-separation:
	bash scripts/scenario-chain-separation.sh

# The invoice prefix separates BOLT 11 in both directions; nothing separates
# BOLT 12. Needs cln-vanilla. About three minutes.
prefix-offers:
	bash scripts/scenario-prefix-offers.sh

# A channel opened by naming its commitment type must be bound to this chain,
# like one opened by letting the nodes choose. Two coop closes, so ten minutes.
named-channel-type:
	bash scripts/scenario-named-channel-type.sh

# The gossip floor at the activation height, with a control either side of it.
gossip-height:
	bash scripts/scenario-gossip-height.sh

# Peering, channel type and both closes against privkeyio's build with nothing
# of ours applied. Needs cln-vanilla.
unified-sigs:
	bash scripts/scenario-unified-sigs.sh

# Why Core Lightning's restamp check cannot fire after the reversal. Uses the
# patched image on purpose; see the script.
restamp:
	bash scripts/scenario-restamp.sh

# 0xa3 on a second-level HTLC, confirmed on chain, with the remote half
# computed by privkeyio's build. Needs cln-vanilla. Twenty-five minutes; set
# SKIP_A=1 to run only the interop half.
htlc-sighash:
	bash scripts/scenario-htlc-sighash.sh

# privkeyio's blake2b-unified at 24d027310 with nothing applied on top. The
# image records the commit at /cln-commit and the build refuses a dirty tree.
cln-vanilla:
	docker build -f Dockerfile.cln-vanilla -t cln-vanilla:lab .

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
