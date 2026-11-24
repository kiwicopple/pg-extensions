# ID kit owns its test environment; no other extension's images are required.
ARG PG_TAG=18.6-trixie
FROM postgres:${PG_TAG} AS build
ARG PG_MAJOR=18
ARG PG_TLE_VERSION=v1.5.3
ARG PGTAP_VERSION=v1.3.4
# The development headers must match the server in the pinned base image.
# PGDG's live repository may already carry a newer minor release.
RUN . /etc/os-release \
 && printf 'deb [signed-by=/usr/local/share/keyrings/postgres.gpg.asc] https://apt-archive.postgresql.org/pub/repos/apt %s-pgdg-archive main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/pgdg-archive.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl flex libkrb5-dev \
      postgresql-server-dev-${PG_MAJOR}=${PG_VERSION} \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir /src && cd /src \
 && curl -fsSL "https://github.com/aws/pg_tle/archive/refs/tags/${PG_TLE_VERSION}.tar.gz" | tar xz --strip-components=1 \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config with_llvm=no -j"$(nproc)" \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config with_llvm=no install DESTDIR=/out
RUN mkdir /pgtap && cd /pgtap \
 && curl -fsSL "https://github.com/theory/pgtap/archive/refs/tags/${PGTAP_VERSION}.tar.gz" | tar xz --strip-components=1 \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
 && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out
FROM postgres:${PG_TAG}
RUN apt-get update \
 && apt-get install -y --no-install-recommends libtap-parser-sourcehandler-pgtap-perl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /
