SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

DEBIAN_VERSION ?= trixie
UBUNTU_VERSION ?= 26.04
HADOOP_VERSION ?= 3.5.0
export DEBIAN_VERSION UBUNTU_VERSION HADOOP_VERSION

# Build args shared by both variants.
HDFS_HOSTNAME ?= hdfs.test

.PHONY: build
build: build-debian

.PHONY: build-debian
build-debian:
	docker build \
	    --build-arg DEBIAN_VERSION=$(DEBIAN_VERSION) \
	    --build-arg HADOOP_VERSION=$(HADOOP_VERSION) \
	    --build-arg HDFS_HOSTNAME=$(HDFS_HOSTNAME) \
	    --file Dockerfile.debian \
	    --tag dyrnq/hdfs:$(DEBIAN_VERSION) \
	    --tag dyrnq/hdfs:latest \
	    --tag dyrnq/hdfs:latest-debian \
	    .

# Local-only build via Dockerfile.debian.mirror. Same output
# tags as build-debian but pulls apt / Hadoop / s6-overlay /
# cargo registry from CN mirrors + a GH proxy, which is much
# faster behind the GFW / on slow links. Dockerfile.debian.mirror
# is git-ignored (see .gitignore) so this target is intended
# for individual contributors, not CI.
#
# Optional HTTP_PROXY/HTTPS_PROXY/NO_PROXY can be passed via
# the environment to make rustup / cargo reach
# static.rust-lang.org through a local proxy — the .mirror
# Dockerfile honors them as build args.
.PHONY: build-debian-mirror
build-debian-mirror:
	docker build \
	    --build-arg DEBIAN_VERSION=$(DEBIAN_VERSION) \
	    --build-arg HADOOP_VERSION=$(HADOOP_VERSION) \
	    --build-arg HDFS_HOSTNAME=$(HDFS_HOSTNAME) \
	    --file Dockerfile.debian.mirror \
	    --tag dyrnq/hdfs:$(DEBIAN_VERSION)-mirror \
	    --tag dyrnq/hdfs:latest-debian-mirror \
	    .

.PHONY: build-ubuntu
build-ubuntu:
	docker build \
	    --build-arg UBUNTU_VERSION=$(UBUNTU_VERSION) \
	    --build-arg HADOOP_VERSION=$(HADOOP_VERSION) \
	    --build-arg HDFS_HOSTNAME=$(HDFS_HOSTNAME) \
	    --file Dockerfile.ubuntu \
	    --tag dyrnq/hdfs:$(UBUNTU_VERSION)-ubuntu \
	    --tag dyrnq/hdfs:latest-ubuntu \
	    .

.PHONY: build-all
build-all: build-debian build-ubuntu

.PHONY: up
up:
	docker compose up -d hdfs-debian

.PHONY: up-ubuntu
up-ubuntu:
	docker compose up -d hdfs-ubuntu

.PHONY: down
down:
	docker compose down

.PHONY: logs
logs:
	docker compose logs -f

.PHONY: shell
shell:
	docker compose exec hdfs-debian /bin/bash

.PHONY: shell-ubuntu
shell-ubuntu:
	docker compose exec hdfs-ubuntu /bin/bash

.PHONY: smoke
smoke:
	./scripts/smoke-test.sh

.PHONY: smoke-kerberos
smoke-kerberos:
	./scripts/smoke-test.sh kerberos

.PHONY: smoke-simple
smoke-simple:
	./scripts/smoke-test.sh simple

.PHONY: smoke-kdc-only
smoke-kdc-only:
	./scripts/smoke-test.sh kdc-only

.PHONY: smoke-datanode-only
smoke-datanode-only:
	./scripts/smoke-test.sh datanode-only

.PHONY: smoke-mount-ro
smoke-mount-ro:
	./scripts/smoke-test.sh mount-ro

.PHONY: smoke-mount-rw
smoke-mount-rw:
	./scripts/smoke-test.sh mount-rw

.PHONY: smoke-disable-envtoxml
smoke-disable-envtoxml:
	./scripts/smoke-test.sh disable-envtoxml

.PHONY: smoke-empty
smoke-empty:
	./scripts/smoke-test.sh empty

.PHONY: smoke-ubuntu
smoke-ubuntu:
	./scripts/smoke-test.sh kerberos dyrnq/hdfs:latest-ubuntu

# Full smoke matrix: 8 modes that together cover every entrypoint
# branch (heredoc render, sed substitution, envtoxml pass + each
# of its three sentinels, simple-mode auto-strip, mount-override
# for :ro and :rw, HDFS_DISABLE_ENVTOXML=1, and empty
# HDFS_SERVICES). Total wall clock ~6-7 min on a fresh image.
.PHONY: smoke-all
smoke-all: smoke-kerberos smoke-simple smoke-kdc-only smoke-datanode-only \
           smoke-mount-ro smoke-mount-rw smoke-disable-envtoxml smoke-empty

# Run `cargo fmt --check` + `cargo test` against the envtoxml Rust
# crate. Same checks CI runs (see .github/workflows/docker.yml `lint`
# job); convenient locally so a contributor can confirm their tree is
# green before pushing. Doesn't touch any docker artifacts — fast
# (~5s cold).
.PHONY: test-envtoxml
test-envtoxml:
	cd tools/envtoxml && cargo fmt --check && cargo test
