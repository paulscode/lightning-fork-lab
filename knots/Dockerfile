# Copied from ../../bitcoin-blake2b-regtest/containers/knots-blake2b and
# pinned to the final v29.4.1 release, with ZMQ enabled: lnd subscribes to
# raw block and transaction notifications over ZMQ.
# Bitcoin Knots with the BLAKE2b proof-of-work change.
#
# Pinned by commit, never by branch: this is a moving development branch and a
# floating build would silently cross consensus revisions (PLAN section 8).
FROM debian:bookworm-slim AS build

ARG KNOTS_REPO=https://github.com/bitcoinknots/bitcoin.git
ARG KNOTS_REF=8c85b1585dac23f964e2dd32045624de7f02aa58
# RDTS consent is mandatory at configure time. IMPLICIT is correct for a test
# chain; a mainnet image would have to make this an explicit operator choice.
ARG RDTS_CONSENT=IMPLICIT

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake pkgconf python3 git ca-certificates \
        libevent-dev libsqlite3-dev libboost-dev libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init -q \
 && git remote add origin "$KNOTS_REPO" \
 && git fetch -q --depth 1 origin "$KNOTS_REF" \
 && git checkout -q FETCH_HEAD \
 && echo "$KNOTS_REF" > /src/PINNED_COMMIT

RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_GUI=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_BENCH=OFF \
        -DBUILD_FUZZ_BINARY=OFF \
        -DENABLE_WALLET=ON \
        -DWITH_ZMQ=ON \
        -DRDTS_CONSENT="$RDTS_CONSENT" \
 && cmake --build build -j"$(nproc)" --target bitcoind bitcoin-cli \
 && strip build/bin/bitcoind build/bin/bitcoin-cli

# ----------------------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libevent-core-2.1-7 libevent-extra-2.1-7 libevent-pthreads-2.1-7 \
        libsqlite3-0 libzmq5 wget \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -m -d /data -u 1000 bitcoin

COPY --from=build /src/build/bin/bitcoind /src/build/bin/bitcoin-cli /usr/local/bin/
COPY --from=build /src/PINNED_COMMIT /etc/knots-pinned-commit
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME /data
EXPOSE 18443 18444
USER bitcoin
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
