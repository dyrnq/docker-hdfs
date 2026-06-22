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

.PHONY: smoke-ubuntu
smoke-ubuntu:
	./scripts/smoke-test.sh kerberos dyrnq/hdfs:latest-ubuntu

.PHONY: smoke-all
smoke-all: smoke-kerberos smoke-simple
