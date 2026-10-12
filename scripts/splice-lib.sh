#!/usr/bin/env bash
# Splicing against the Core Lightning port: helpers for the containers
# sp-lf (Lightning Fork, splicing build) and sp-cln (the port's release), on
# the lab network and its BLAKE2b regtest.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
N=lightning-fork-lab_lab
LF_IMAGE=${LF_IMAGE:-lightning-fork:splice}
CLN_IMAGE=${CLN_IMAGE:-cln-blake2b-release:v7}

lf()  { docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
cln() { docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data "$@"; }

start_lf() {
	docker run -d --name sp-lf --network $N -v sp-lf-data:/root/.lnd "$LF_IMAGE" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 --bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 --externalip=sp-lf:9735 \
		--tlsextradomain=sp-lf --alias=sp-lf \
		--debuglevel=info,PEER=debug,SPLC=trace,HSWC=debug,CNCT=debug,LNWL=debug,DISC=debug \
		--protocol.splice --accept-keysend >/dev/null
}

start_cln() {
	docker run -d --name sp-cln --network $N -v sp-cln-data:/data "$CLN_IMAGE" \
		--network=regtest --lightning-dir=/data --bitcoin-rpcconnect=knots-b2b \
		--bitcoin-rpcport=18443 --bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr=sp-cln:9735 --alias=sp-cln \
		--log-level=debug --disable-plugin=cln-grpc --disable-plugin=clnrest \
		--disable-plugin=cln-bip353 --experimental-splicing >/dev/null
}

lf_synced()  { [ "$(lf getinfo 2>/dev/null | jq -r .synced_to_chain)" = true ]; }
cln_synced() { [ "$(cln getinfo 2>/dev/null | jq -r .blockheight)" = "$(b2b getblockcount)" ]; }
wait_synced() {
	wait_for "sp-lf synced" 120 lf_synced
	wait_for "sp-cln synced" 120 cln_synced
}
