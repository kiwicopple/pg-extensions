# Official Postgres image plus pg_tle built from source.
#
#   docker build --build-arg PG_TAG=17.11-trixie --build-arg PG_MAJOR=17 .
#
# compose.yaml passes both args per service. pg_tle v1.5.3 (2026-10-08) is the
# newest release; it supports Postgres 12 to 19 (18 since v1.5.2).
ARG PG_TAG=17.11-trixie

FROM postgres:${PG_TAG} AS build
ARG PG_MAJOR=17
ARG PG_TLE_VERSION=v1.5.3
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl flex libkrb5-dev \
      postgresql-server-dev-${PG_MAJOR} \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir /src && cd /src \
 && curl -fsSL "https://github.com/aws/pg_tle/archive/refs/tags/${PG_TLE_VERSION}.tar.gz" | tar xz --strip-components=1 \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config with_llvm=no -j"$(nproc)" \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config with_llvm=no install DESTDIR=/out

FROM postgres:${PG_TAG}
ARG PG_TLE_VERSION=v1.5.3
COPY --from=build /out/ /
LABEL org.pg-permissions.pg_tle="${PG_TLE_VERSION}"
