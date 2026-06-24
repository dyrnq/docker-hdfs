#!/usr/bin/env bash
# Entrypoint for dyrnq/hdfs.
#
# 1. Render runtime config (krb5.conf, hdfs-site.xml, core-site.xml)
#    by substituting env-driven placeholders.
# 2. On first boot (no KDC database on the volume), initialize the
#    realm and create the hdfs/HTTP service principals + a
#    testuser principal. The hdfs keytab is shared by both NameNode
#    and DataNode because the principal is the same in this
#    single-container deployment.
# 3. Generate a self-signed keystore for HTTPS handlers.
# 4. Hand off to s6-overlay.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configurable env
# ---------------------------------------------------------------------------
: "${HDFS_HOSTNAME:=hdfs.test}"
: "${KRB5_REALM:=TEST.LOCAL}"
: "${KRB5_KDC:=localhost}"
: "${KRB5_DOMAIN:=test}"
: "${KRB5_PASS:=}"
# Smoke-test-only principal. The password is intentionally weak
# ("testpass" by default) — this is a credential for exercising
# the SASL path in the smoke test, not a real user. Override via
# KRB5_TESTUSER_PASS if you're shipping this image somewhere that
# actually exposes the testuser principal.
: "${KRB5_TESTUSER_PASS:=testpass}"
: "${HDFS_NAMENODE_RPC_PORT:=8020}"
: "${KEYSTORE_PASS:=changeit}"
# Auth protocol: "kerberos" (default) or "simple". Decoupled
# from HDFS_SERVICES (which controls which s6-rc services start):
# HDFS_SERVICES picks the service layout, HADOOP_SECURITY_
# AUTHENTICATION picks the SASL mechanism. In simple mode we
# (a) auto-strip the kerberos-only properties from hdfs-site.xml
# / core-site.xml via envtoxml's `!remove` sentinel — see the
# pre-sed block below for the exact list. Without (a), the RPC
# server keeps advertising [TOKEN, KERBEROS] as the only
# available SASL mechanisms and SIMPLE clients are rejected
# (issue #13); with (a), the simple mode becomes a one-env-var
# deployment (issue #14). The KDC bootstrap block below is also
# gated on this var.
#
# HDFS_SERVICES (read in the next code block, not here) is the
# primary switch for service layout; see its comment block.
# The legacy shortcut `HADOOP_SECURITY_AUTHENTICATION=simple` is
# still accepted and is equivalent to
# HDFS_SERVICES=namenode,datanode.
#
# Env propagation to the s6 longruns is reliable in simple mode too
# because simple mode no longer bypasses the entrypoint — see
# `hdfs-common.sh: hdfs_auth_mode` for the XML-vs-env discussion of
# which signal the run scripts prefer.
: "${HADOOP_SECURITY_AUTHENTICATION:=kerberos}"

# Disable the envtoxml merge pass (the `<NAME>.XML_<key>=<value>`
# injection) without having to bind-mount the XMLs read-only.
# `HDFS_DISABLE_ENVTOXML=1` makes the entrypoint skip envtoxml but
# keep the heredoc render, so the in-image XMLs at
# /opt/hadoop/etc/hadoop/ are exactly what the heredoc produced
# (with placeholder substitution + simple-mode auto-strip still
# applied if applicable). Useful when an operator wants the
# heredoc defaults but does NOT want their `HDFS-SITE.XML_*` env
# vars to silently mutate the rendered file. NOTE: in
# HADOOP_SECURITY_AUTHENTICATION=simple mode, envtoxml is also
# how the kerberos-only auto-strip (issues #13, #14) is applied —
# disabling envtoxml in simple mode leaves the kerberos-only
# properties in the rendered XML, which makes the daemons refuse
# to start (kinit has nowhere to go). The entrypoint prints a
# loud WARN for that combination (see below).
: "${HDFS_DISABLE_ENVTOXML:=0}"

# Backward compat: HADOOP_SECURITY_AUTHENTICATION=simple historically
# implied "no KDC". Translate that into HDFS_SERVICES=namenode,datanode
# IF the operator did not explicitly set HDFS_SERVICES. We use `${VAR
# :-default}` (assign-if-unset-or-empty) but then we lose the ability
# to tell "user set it" from "default applied". Workaround: probe
# whether HDFS_SERVICES was set in the env (the entrypoint's own
# export-then-read pattern is fragile; safer to read the literal env).
# We accept both spellings: HDFS_SERVICES=foo and the shell-exported
# form. If unset, derive from HADOOP_SECURITY_AUTHENTICATION.
if [ -z "${HDFS_SERVICES+set}" ]; then
    case "${HADOOP_SECURITY_AUTHENTICATION}" in
        [Ss]imple) HDFS_SERVICES=namenode,datanode ;;
        *)        HDFS_SERVICES=namenode,datanode,krb5kdc,kadmind ;;
    esac
fi

# Loud warning when HDFS_DISABLE_ENVTOXML=1 conflicts with
# HADOOP_SECURITY_AUTHENTICATION=simple: the simple-mode
# auto-strip (issues #13, #14) is implemented INSIDE the
# envtoxml pass (the entrypoint spawns `env HDFS-SITE.XML_*
# !remove … envtoxml file`). Disabling envtoxml in simple mode
# means the kerberos-only properties (keytabs, SPNs,
# dfs.data.transfer.protection, hadoop.rpc.protection,
# dfs.block.access.token.enable=true, hadoop.security.authorization=
# true) all stay in the rendered XML, and the NN/DN run scripts
# will hit kinit / SASL failures with no KDC in the container.
# The container won't FATAL here — it will run, but the daemons
# will loop-restart. Better to print loud + exit non-zero so the
# operator notices at `docker run` time, not 30s later when the
# first s6 restart storm hits. The exit code is 0 actually —
# we don't want to break compose orchestration on a warning.
# Just print very loud and continue.
if [ "${HDFS_DISABLE_ENVTOXML}" = "1" ] && \
   { [ "${HADOOP_SECURITY_AUTHENTICATION}" = "simple" ] || \
     [ "${HADOOP_SECURITY_AUTHENTICATION}" = "Simple" ]; }; then
    echo "================================================================" >&2
    echo "WARN: HDFS_DISABLE_ENVTOXML=1 + HADOOP_SECURITY_AUTHENTICATION=simple" >&2
    echo "WARN: The simple-mode auto-strip is implemented via envtoxml." >&2
    echo "WARN: Disabling envtoxml leaves kerberos-only properties" >&2
    echo "WARN: (keytabs, SPNs, dfs.data.transfer.protection, …) in the" >&2
    echo "WARN: rendered XML, and the NN/DN daemons will fail to start." >&2
    echo "WARN: Either unset HDFS_DISABLE_ENVTOXML, or pass the 9" >&2
    echo "WARN: HDFS-SITE.XML_*/CORE-SITE.XML_* !remove env vars manually." >&2
    echo "================================================================" >&2
fi

HADOOP_ETC=/opt/hadoop/etc/hadoop
KEYTAB=/etc/hadoop/hdfs.keytab
KEYSTORE=/etc/hadoop/keystore.jks

# ---------------------------------------------------------------------------
# Base Hadoop XML configs (hdfs-site.xml, core-site.xml).
#
# These are produced at container start by heredoc functions
# (hdfs_site_xml / core_site_xml), not shipped in the image. The
# upstream Hadoop tarball extracts empty
# `<configuration></configuration>` files at /opt/hadoop/etc/hadoop/
# (verified against the Apache release tarball), so falling back to
# those defaults would lose every kerberos principal / keytab /
# dfs.replication / bind-host fix — the cluster would boot with
# Hadoop's no-auth, no-replication defaults. Keeping the source of
# truth in the entrypoint also avoids a class of foot-guns:
# rootfs/* is in the image layer, so edits there require a rebuild
# + repush; putting the XML in the entrypoint means the rendering
# pipeline is reviewable in one place.
#
# Quoted heredocs (`<<'EOF_HDFS_SITE'`) — bash performs NO parameter
# expansion; the 4 __PLACEHOLDER__ tokens are resolved by the sed
# pass in the rendering block below. The XML comments inside the
# heredoc (issues #8/#11/#12 design notes) survive verbatim — sed
# doesn't touch comment contents.
#
# The heredoc DELIMITERs (EOF_HDFS_SITE / EOF_CORE_SITE) do not
# appear anywhere in the XML body — verified by grep before this
# block was committed. If you ever add a property whose VALUE
# contains the literal string `EOF_HDFS_SITE` or `EOF_CORE_SITE`,
# rename the delimiter.
# ---------------------------------------------------------------------------
hdfs_site_xml() {
    cat <<'EOF_HDFS_SITE'
<?xml version="1.0"?>
<configuration>
    <property><name>dfs.replication</name><value>1</value></property>

    <property><name>dfs.namenode.kerberos.principal</name><value>hdfs/__HDFS_HOSTNAME__@__KRB5_REALM__</value></property>
    <property><name>dfs.namenode.keytab.file</name><value>/etc/hadoop/hdfs.keytab</value></property>
    <!--
        dfs.namenode.rpc-address + dfs.namenode.rpc-bind-host:
        the advertised RPC address (what clients/DataNodes connect to)
        is split from the bind address (what the socket listens on).

        rpc-address = __HDFS_HOSTNAME__:port  — NOT 0.0.0.0. This
        matters for the DataNode's registered ip_addr: the NameNode
        OVERWRITES the DataNode's reported ipAddr with the source IP of
        the DN→NN registration RPC (see DatanodeManager.registerDatanode,
        DatanodeManager.java ~line 1204: nodeReg.setIpAddr(ip)). With
        rpc-address=0.0.0.0 the DN connects to its NN over loopback
        (0.0.0.0 resolves to 127.0.0.1), so the NN records ip_addr=
        127.0.0.1 — which breaks every cross-pod client (CSI mounts,
        opendal/hdfs-native) that connects to DataNodes by ip_addr.
        Pointing rpc-address at __HDFS_HOSTNAME__ (resolved to the pod
        IP) makes the DN connect over its real interface, so the NN
        records the real IP. See GitHub issue #8.

        rpc-bind-host = 0.0.0.0 — keeps the NameNode listening on ALL
        interfaces (single-container dev/test, port-published docker,
        etc.) regardless of what rpc-address advertises. Without this,
        rpc-address=__HDFS_HOSTNAME__ would also narrow the bind to
        that one IP. (NameNode.getRpcServerBindHost,
        NameNode.java ~line 743.)

        Effective "ALL" scope note: with the image's default
        JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true (set in the
        Dockerfile ENV, see Dockerfile.debian / Dockerfile.ubuntu),
        the JVM only opens AF_INET sockets, so "ALL interfaces" here
        means "all IPv4 interfaces". Operators on IPv6-only clusters
        who need the IPv6 half of the dual-stack can pass
        `-e JAVA_TOOLUTIONS=-Djava.net.preferIPv4Stack=false` at run
        time — that restores the JVM's dual-stack behavior and the
        bind reverts to `[::]:port` in /proc/net/tcp6 (the issue #15
        state this Dockerfile ENV prevents by default).

        k8s caveat: __HDFS_HOSTNAME__ must resolve to the pod IP from
        inside the pod. A short name mapped to 127.0.0.1 in /etc/hosts
        (a common k8s pod default) defeats this — use the pod's
        headless-Service FQDN or set HDFS_HOSTNAME to the pod IP. The
        same value already drives the Kerberos principal and TLS cert
        CN, so they stay aligned. To override at runtime without
        rebuilding, set HDFS-SITE.XML_dfs.namenode.rpc-address=<ip>:<port>
        (see the env→XML injection documented in README).
    -->
    <property><name>dfs.namenode.rpc-address</name><value>__HDFS_HOSTNAME__:__HDFS_NAMENODE_RPC_PORT__</value></property>
    <property><name>dfs.namenode.rpc-bind-host</name><value>0.0.0.0</value></property>
    <!-- HTTPS port baked in (was HDFS_NAMENODE_HTTPS_PORT; that special
         env was removed — override via HDFS-SITE.XML_dfs.namenode.
         https-address=0.0.0.0:<port> instead). -->
    <property><name>dfs.namenode.https-address</name><value>0.0.0.0:9871</value></property>

    <property><name>dfs.datanode.kerberos.principal</name><value>hdfs/__HDFS_HOSTNAME__@__KRB5_REALM__</value></property>
    <property><name>dfs.datanode.keytab.file</name><value>/etc/hadoop/hdfs.keytab</value></property>
    <!--
        dfs.datanode.hostname: sets ONLY the DatanodeID.hostName field
        (the hostname shown by `dfsadmin -report` and returned to
        Hadoop-native clients in block-location lookups). It does NOT
        set ip_addr — that comes from the DN→NN registration RPC's
        source IP (see the rpc-address comment above + issue #8).
        Pinning it to __HDFS_HOSTNAME__ keeps the advertised hostname
        consistent with the Kerberos principal / TLS cert CN / what
        consumers use to reach the cluster. Hadoop-native clients that
        prefer connecting by hostname can set
        dfs.client.use.datanode.hostname=true in their own core-site.xml;
        clients that hardcode ip_addr (opendal/hdfs-native) are served
        by the rpc-address fix above instead.
    -->
    <property><name>dfs.datanode.hostname</name><value>__HDFS_HOSTNAME__</value></property>
    <!--
        DataNode address binding (issue #11, extended for issue #15):
        The address + http-address + https-address + ipc-address values
        are set to __HDFS_HOSTNAME__:port, NOT 0.0.0.0:port. This
        mirrors the NN rpc-address fix above (issue #8) and addresses
        a separate regression on IPv6-first JVMs (Debian 13 +
        OpenJDK 21).

        Background: when a Java NIO ServerSocket binds "0.0.0.0",
        `InetSocketAddress` calls `getAllByName("0.0.0.0")`. On a system
        where `net.ipv6.bindv6only=0`, that returns the IPv6 wildcard
        FIRST, so the JVM creates only an IPv6 listener (`[::]:port` in
        /proc/net/tcp6). IPv4-only clients (opendal, hdfs-native,
        anything that resolves A-only) get ECONNREFUSED on the
        registered ip_addr (which is IPv4, see issue #8). Pointing
        the address values at a hostname (resolved to A + AAAA records)
        makes the DN bind a non-IPv6-wildcard address — in practice
        an IPv4-mapped IPv6 socket on `::ffff:<resolved-ip>:port` in
        /proc/net/tcp6 (FFFF0000 prefix). The kernel still routes
        IPv4 input to that socket on a dual-stack system, so IPv4
        clients can connect — but the bind is no longer the pure
        IPv6 wildcard, and `dfsadmin -report` / /proc/net/tcp[6] no
        longer report an IPv6-only listener.

        ipc-address (9867) was previously left at its Hadoop default
        `0.0.0.0:9867`, which made the DN IPC bind as the pure IPv6
        wildcard dual-stack on the same Debian 13 / OpenJDK 21 systems
        that prompted issue #11. The hostname pattern below brings
        it into the same IPv4-mapped IPv6 family as data / http /
        https. With the image's default
        `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true` (set in
        the Dockerfile ENV — see Dockerfile.debian / Dockerfile.ubuntu),
        hostname resolution also skips AAAA records, so even if the
        hostname pattern fell back to 0.0.0.0 (the k8s /etc/hosts
        pitfall noted on rpc-address above) the bind would still
        resolve as `00000000:268B` in /proc/net/tcp. The hostname
        pattern stays here as defensive coding so this property
        family is uniform regardless of the JVM stack preference.

        Note on `dfs.datanode.bind-host`: that config does NOT exist
        in Hadoop 3.5.0 — `DFSConfigKeys.DFS_DATANODE_BIND_HOST_KEY`
        is absent (only NN / Balancer / JournalNode / Provided-aliasmap
        have bind-host keys; DN does not). The IPv6 fix is carried by
        the hostname-pattern above alone; a `bind-host` line here
        would be silently ignored. Don't reintroduce it.

        k8s caveat: same as rpc-address — __HDFS_HOSTNAME__ must
        resolve to the pod IP from inside the pod. Override at
        runtime via env:
        HDFS-SITE.XML_dfs.datanode.address=<ip>:<port>
        + HDFS-SITE.XML_dfs.datanode.http.address=<ip>:9864
        + HDFS-SITE.XML_dfs.datanode.https.address=<ip>:9865
        + HDFS-SITE.XML_dfs.datanode.ipc.address=<ip>:9867
        (envtoxml is the documented escape hatch; see README).
    -->
    <property><name>dfs.datanode.address</name><value>__HDFS_HOSTNAME__:9866</value></property>
    <property><name>dfs.datanode.http.address</name><value>__HDFS_HOSTNAME__:9864</value></property>
    <property><name>dfs.datanode.https.address</name><value>__HDFS_HOSTNAME__:9865</value></property>
    <property><name>dfs.datanode.ipc.address</name><value>__HDFS_HOSTNAME__:9867</value></property>

    <property><name>dfs.web.authentication.kerberos.principal</name><value>HTTP/__HDFS_HOSTNAME__@__KRB5_REALM__</value></property>
    <property><name>dfs.web.authentication.kerberos.keytab</name><value>/etc/hadoop/hdfs.keytab</value></property>

    <property><name>dfs.block.access.token.enable</name><value>true</value></property>
    <property><name>dfs.data.transfer.protection</name><value>authentication</value></property>
    <property><name>dfs.http.policy</name><value>HTTP_ONLY</value></property>

    <property><name>ignore.secure.ports.for.testing</name><value>true</value></property>
    <property><name>dfs.namenode.secondary.http-address</name><value>0.0.0.0:0</value></property>

    <property><name>dfs.namenode.name.dir</name><value>file:///var/lib/hadoop/namenode</value></property>
    <property><name>dfs.datanode.data.dir</name><value>file:///var/lib/hadoop/datanode</value></property>
</configuration>
EOF_HDFS_SITE
}

core_site_xml() {
    cat <<'EOF_CORE_SITE'
<?xml version="1.0"?>
<configuration>
    <property><name>fs.defaultFS</name><value>hdfs://__HDFS_HOSTNAME__:__HDFS_NAMENODE_RPC_PORT__</value></property>
    <property><name>hadoop.security.authentication</name><value>__HADOOP_SECURITY_AUTHENTICATION__</value></property>
    <property><name>hadoop.security.authorization</name><value>true</value></property>
    <property><name>hadoop.rpc.protection</name><value>authentication</value></property>
</configuration>
EOF_CORE_SITE
}

# Build the s6-rc user bundle's contents.d/ from HDFS_SERVICES. The
# image ships contents.d/ EMPTY (no service is "on by default"); the
# entrypoint is the single source of truth for which longruns start
# in this container. A service in HDFS_SERVICES gets a zero-byte
# file in contents.d/; a service NOT in HDFS_SERVICES gets no file
# at all. s6-rc-compile (run by /init, AFTER this entrypoint) reads
# contents.d/ to decide what goes in the user bundle, so the
# mutation here is what determines the live service layout.
#
# We `touch` (not `: >` and not `rm + recreate`) for two reasons:
#   1. The image no longer ships any contents.d/ files, so
#      `touch` is unambiguous — "create an empty marker if not
#      present". `: >` would truncate an existing file but we
#      have no existing files to truncate.
#   2. `touch` is a no-op for an already-present empty file
#      (mtime update only), so re-runs of the entrypoint in a
#      restarted container don't churn the dir mtime.
#
# HDFS_SERVICES: which s6-rc services to start. Comma-separated
# subset of {namenode, datanode, krb5kdc, kadmind}. Default
# depends on HADOOP_SECURITY_AUTHENTICATION (kerberos → all 4,
# simple → namenode,datanode). Use it directly for partial
# layouts, e.g.
#   HDFS_SERVICES=krb5kdc,kadmind              # KDC only (for keytab distribution)
#   HDFS_SERVICES=namenode                     # NN only (no DN, no KDC)
#
# The HADOOP_SECURITY_AUTHENTICATION variable still controls
# which auth protocol the hadoop daemons use (hadoop.security.
# authentication=kerberos|simple) and whether the entrypoint
# bootstraps an embedded KDC. The two variables are checked for
# consistency below.
# NOTE: HDFS_SERVICES is allowed to be EMPTY (`-e HDFS_SERVICES=`).
# An empty value produces a valid no-services layout — s6-rc-compile
# accepts an empty user bundle (no contents.d/ files), /init runs
# s6-svscan against an empty bundle (no supervised longruns), and
# the container stays up doing nothing. The KDC bootstrap block
# below is gated on HADOOP_SECURITY_AUTHENTICATION, NOT on
# HDFS_SERVICES, so an empty + kerberos layout will still write
# the KDC database + keytab to /var/lib/krb5kdc (useful as a
# sidecar bootstrap: prepare the KDC volume in one container,
# mount it into a real HDFS_SERVICES=krb5kdc,kadmind container
# later). The unset→default fallback above (lines 65-70) is the
# ONLY place HDFS_SERVICES gets a default — we deliberately do
# NOT `: ${HDFS_SERVICES:=…}` here, since that would clobber an
# operator's explicit empty value.

# Validate HDFS_SERVICES: each token must be one of the four
# known services. Unknown names are a hard error because
# silently dropping them would be surprising (an operator
# typo'ing `namendoe` would end up with no NN and a mystery).
# Empty HDFS_SERVICES is allowed and produces a 0-iteration loop
# (bash `for x in` with an empty word list does nothing).
HDFS_SERVICES_VALID="namenode datanode krb5kdc kadmind"
for svc in ${HDFS_SERVICES//,/ }; do
    case " $HDFS_SERVICES_VALID " in
        *" $svc "*) ;;
        *)
            echo "FATAL: HDFS_SERVICES='$svc' is not a known service." >&2
            echo "FATAL: Valid services: $HDFS_SERVICES_VALID" >&2
            exit 1
            ;;
    esac
done

# Log the resolved layout. No cross-validation: HDFS_SERVICES picks
# the service set, HADOOP_SECURITY_AUTHENTICATION picks the auth
# protocol, and the entrypoint does NOT try to detect "broken"
# combinations. A few that the entrypoint could have caught, but
# deliberately does not:
#
#   * kerberos + no krb5kdc in HDFS_SERVICES — NN/DN run scripts
#     do `kinit -kt ... hdfs/...@REALM` and will loop-restart if
#     the KDC is missing. The container is non-functional, but
#     the operator may be running a multi-container layout where
#     KRB5_KDC points at a remote KDC (the run scripts use
#     KRB5_KDC for the wait, not the s6 dep). We let the operator
#     have the runtime error.
#   * datanode + no namenode in HDFS_SERVICES — DN's
#     hdfs_wait_for_namenode will time out. Same call.
#   * kadmind + no krb5kdc in HDFS_SERVICES — kadmind's
#     `nc -z localhost 88` will time out. Same call.
#   * simple + krb5kdc in HDFS_SERVICES — wasteful but the KDC
#     services detect simple auth and skip kinit. Operator's
#     choice.
#
# The point of dropping all these checks is that the entrypoint
# can now support partial layouts (HDFS_SERVICES=namenode,
# HDFS_SERVICES=datanode, HDFS_SERVICES=krb5kdc,kadmind, …) that
# would have failed the validation. The dyn-dep block below
# builds the dep graph from whatever subset is in HDFS_SERVICES,
# so a single-service start works as long as its run script's
# waits can resolve against an external service via the
# appropriate env var (HDFS_NAMENODE_HOST, KRB5_KDC).
echo "=== HDFS_SERVICES=${HDFS_SERVICES} (HADOOP_SECURITY_AUTHENTICATION=${HADOOP_SECURITY_AUTHENTICATION}) ==="

# Build the contents.d file list from the desired HDFS_SERVICES.
# The image ships an empty contents.d/ — no service is enabled by
# default. We `touch` one zero-byte file per service in
# HDFS_SERVICES; services NOT in the list simply have no file,
# which is the supported s6-rc way to exclude them from the user
# bundle. (s6-rc-compile keys off file existence, not content.)
for svc in ${HDFS_SERVICES//,/ }; do
    touch "/etc/s6-overlay/s6-rc.d/user/contents.d/${svc}"
done

# Build the s6-rc dep graph dynamically from HDFS_SERVICES. The
# image ships empty `dependencies.d/` dirs under each service —
# no baked-in edges, so the entrypoint is the sole source of
# truth for which edges exist. We `touch` an edge file ONLY when
# BOTH the source and the target are in HDFS_SERVICES; if either
# is missing, no edge is created and s6-rc-compile sees a service
# with no dep. This is what makes single-service starts
# (HDFS_SERVICES=datanode, HDFS_SERVICES=namenode, …) work: the
# run script's internal waits (hdfs_wait_for_namenode,
# hdfs_wait_for_kdc) cover the case where the upstream service
# is in another container.
#
# Known edges:
#   datanode → namenode   (DN registers with the NN RPC)
#   namenode → krb5kdc    (NN kinit against the embedded KDC)
#   kadmind  → krb5kdc    (kadmind waits for KDC port 88)
#
# We also `mkdir -p` the dependencies.d/ dir defensively. It
# ships in the image (the COPY step creates it as part of the
# s6-rc.d/ tree), so the mkdir is a no-op today, but it makes
# this block robust to a future image that ships the dirs empty
# for some reason.
_has() { case " ${HDFS_SERVICES//,/ } " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
declare -A DEPS=(
    [datanode]=namenode
    [namenode]=krb5kdc
    [kadmind]=krb5kdc
)
for src in "${!DEPS[@]}"; do
    tgt=${DEPS[$src]}
    if _has "$src" && _has "$tgt"; then
        mkdir -p "/etc/s6-overlay/s6-rc.d/${src}/dependencies.d"
        : > "/etc/s6-overlay/s6-rc.d/${src}/dependencies.d/${tgt}"
    fi
done
unset -f _has
unset DEPS

# ---------------------------------------------------------------------------
# Render /etc/krb5.conf
# ---------------------------------------------------------------------------
echo "=== Rendering /etc/krb5.conf (realm=${KRB5_REALM}, kdc=${KRB5_KDC}) ==="
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${KRB5_REALM}
    udp_preference_limit = 1
    rdns = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${KRB5_REALM} = {
        kdc = ${KRB5_KDC}:88
        admin_server = ${KRB5_KDC}:749
    }

[domain_realm]
    .${KRB5_DOMAIN} = ${KRB5_REALM}
    ${KRB5_DOMAIN} = ${KRB5_REALM}
EOF

# ---------------------------------------------------------------------------
# Render hadoop XML config
# ---------------------------------------------------------------------------
echo "=== Rendering hdfs-site.xml / core-site.xml (host=${HDFS_HOSTNAME}) ==="
TMPDIR_ENT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_ENT}"' EXIT

# Simple-mode auto-strip (issues #13, #14):
# When HADOOP_SECURITY_AUTHENTICATION=simple the kerberos-only properties
# baked into hdfs-site.xml / core-site.xml make the RPC server advertise
# [TOKEN, KERBEROS] as the only available SASL mechanisms (even though
# no KDC is present), so SIMPLE clients are rejected with
# "SIMPLE authentication is not enabled. Available:[TOKEN, KERBEROS]".
#
# The fix is to delete those properties from the rendered XMLs. We
# re-use envtoxml's `!remove` sentinel (see tools/envtoxml/src/main.rs)
# by passing the same env vars the smoke test passes via
# `docker run -e` directly to the envtoxml child process — that
# way the entrypoint does NOT need a new code path; the envtoxml
# pass below sees the sentinels and applies them just like it would
# for a user-supplied override.
#
# The keys cannot be `export`ed in this shell because bash rejects
# env var names containing `.` or `-` as "not a valid identifier"
# (HDFS-SITE.XML_dfs.foo fails). We must inject them into the
# envtoxml child via `env VAR=value … envtoxml file` instead. That
# also keeps the entrypoint's own env (which propagates to the s6
# longruns) free of the strip keys — only envtoxml sees them.
case "${HADOOP_SECURITY_AUTHENTICATION}" in
    [Ss]imple)
        echo "=== simple mode: auto-strip kerberos-only XML properties (issues #13, #14) ==="
        ;;
esac

for f in hdfs-site.xml core-site.xml; do
    # Skip operator-mounted XMLs entirely. The entrypoint's
    # contract for bind-mounted files is "the operator's file IS
    # the rendered file" — no heredoc, no sed, no cp-back. The
    # is_xml_overridden check (mountpoint -q + [ ! -w ]) catches
    # both :ro and :rw bind-mounts. Putting the check at the top
    # of the loop (instead of after the heredoc+sed pass) avoids
    # ~0.01s × 2 files of wasted work per container start, and —
    # more importantly — keeps the "do nothing for operator files"
    # contract visible at the top of the loop body (issue 5).
    if is_xml_overridden "${HADOOP_ETC}/${f}"; then
        echo "=== ${HADOOP_ETC}/${f} is bind-mounted or read-only (operator override); skipping heredoc render ==="
        continue
    fi

    # Source the base XML from the bash heredoc functions defined
    # further down in this file (hdfs_site_xml / core_site_xml).
    # The XMLs are NOT in the image's rootfs tree — the upstream
    # Hadoop tarball ships empty <configuration></configuration>
    # files at /opt/hadoop/etc/hadoop/ (no kerberos principal,
    # no dfs.replication, no bind-host fixes for issues #8/#11),
    # so falling back to those defaults would break kerberos
    # auth and the DN bind. The heredoc functions are the
    # single source of truth.
    #
    # Heredoc → `.src` first, then sed reads `.src` and writes the
    # final tmpfile. We can't write the heredoc directly to the
    # sed target because the shell truncates the redirect target
    # BEFORE sed reads it (sed would see an empty file). The
    # two-step split avoids that.
    src="${TMPDIR_ENT}/${f}.src"
    case "${f}" in
        hdfs-site.xml) hdfs_site_xml > "${src}" ;;
        core-site.xml) core_site_xml > "${src}" ;;
        *) echo "FATAL: unknown XML ${f}" >&2; exit 1 ;;
    esac
    sed \
        -e "s|__HDFS_HOSTNAME__|${HDFS_HOSTNAME}|g" \
        -e "s|__KRB5_REALM__|${KRB5_REALM}|g" \
        -e "s|__HDFS_NAMENODE_RPC_PORT__|${HDFS_NAMENODE_RPC_PORT}|g" \
        -e "s|__HADOOP_SECURITY_AUTHENTICATION__|${HADOOP_SECURITY_AUTHENTICATION}|g" \
        "${src}" > "${TMPDIR_ENT}/${f}"
done

# Write the rendered XMLs back to the in-image paths so Hadoop reads
# the placeholder-substituted versions on container start. The
# Dockerfile does NOT do any build-time substitution — the XMLs
# ship with literal `__HDFS_HOSTNAME__` placeholders and this
# entrypoint is the sole substitution point. The cp-back is skipped
# when the destination is operator-owned: either a bind-mount (any
# kind — `:ro` or `:rw`) or a read-only filesystem. The
# is_xml_overridden helper checks both signals; the rationale is
# that a bind-mounted XML is the operator's authoritative copy,
# and silently overwriting it (the previous `[ ! -w ]`-only guard
# allowed this for `:rw` mounts) is a footgun: an operator who
# `-v`s a customized XML would see it replaced by the heredoc
# defaults on every container start. Detecting bind-mounts via
# `mountpoint -q` (util-linux; ships in both Debian and Ubuntu
# bases) is the only portable way to know the path is a mount
# source regardless of writability.
#
# `mountpoint -q` returns 0 if the path is a mountpoint, non-zero
# otherwise. We OR it with `[ ! -w ]` to cover non-bind cases
# (e.g. the upper layer is read-only).
is_xml_overridden() {
    local path=$1
    mountpoint -q "${path}" 2>/dev/null || [ ! -w "${path}" ]
}
for f in hdfs-site.xml core-site.xml; do
    if is_xml_overridden "${HADOOP_ETC}/${f}"; then
        echo "=== ${HADOOP_ETC}/${f} is bind-mounted or read-only (operator override); using source as-is ==="
        continue
    fi
    # The heredoc render above may have been skipped if the path
    # became a mount between the two checks (race; rare). Belt-
    # and-suspenders: skip the cp-back too if there's nothing
    # to copy. Without this, `cp -f` would error out on a missing
    # source and the container would FATAL on startup.
    if [ ! -f "${TMPDIR_ENT}/${f}" ]; then
        echo "=== ${HADOOP_ETC}/${f}: no rendered XML to copy (heredoc render skipped) ==="
        continue
    fi
    cp -f "${TMPDIR_ENT}/${f}" "${HADOOP_ETC}/${f}"
done

# Env→XML injection (inspired by apache/ozone envtoconf). After the
# placeholder substitution above, any env var named
# `<NAME>.XML_<hadoop-key>=<value>` is merged into `<name>.xml`:
# same key overwrites the existing <value> in place; a new key is
# appended before </configuration>. This lets an operator tweak one
# property (e.g. switch dfs.namenode.rpc-address to a pod IP in k8s)
# with `-e HDFS-SITE.XML_dfs.namenode.rpc-address=...` instead of
# bind-mounting a whole XML. Values are XML-escaped, config keys pass a
# whitelist, and the output is well-formed by construction. The merger is
# a static Rust binary (`/usr/local/bin/envtoxml`, built in a multi-stage
# Dockerfile from tools/envtoxml/) — no python3 runtime, no bash quoting
# hazards. See tools/envtoxml/src/main.rs for the full contract. Skipped
# for operator-owned XMLs (bind-mount or read-only), consistent with
# the cp-back guard above: an operator who mounts their own XML is
# fully in charge and is not second-guessed by env vars. A separate
# `HDFS_DISABLE_ENVTOXML=1` opt-out is also honored for the writable
# case (see below).
for f in hdfs-site.xml core-site.xml; do
    if is_xml_overridden "${HADOOP_ETC}/${f}"; then
        # Bind-mount or read-only → envtoxml skip (operator owns the file).
        continue
    fi
    if [ "${HDFS_DISABLE_ENVTOXML:-0}" = "1" ]; then
        echo "=== ${HADOOP_ETC}/${f}: envtoxml disabled (HDFS_DISABLE_ENVTOXML=1) ==="
        continue
    fi
    # Build the envtoxml argv for this XML. In simple mode we inject
    # the kerberos-strip keys via `env VAR=value …` (bash's
    # `export VAR=value` rejects names with `.` or `-` as "not a
    # valid identifier", but `env` accepts any name). The strip
    # keys must live in the envtoxml child process's env, not
    # the entrypoint's, because the entrypoint's env propagates
    # to the s6 longruns — we don't want the strip keys leaking
    # there. In kerberos mode no extra args are needed; the base
    # `envtoxml "${HADOOP_ETC}/${f}"` invocation runs directly.
    case "${HADOOP_SECURITY_AUTHENTICATION}" in
        [Ss]imple)
            set -- env \
                "HDFS-SITE.XML_dfs.namenode.kerberos.principal=!remove" \
                "HDFS-SITE.XML_dfs.namenode.keytab.file=!remove" \
                "HDFS-SITE.XML_dfs.datanode.kerberos.principal=!remove" \
                "HDFS-SITE.XML_dfs.datanode.keytab.file=!remove" \
                "HDFS-SITE.XML_dfs.web.authentication.kerberos.principal=!remove" \
                "HDFS-SITE.XML_dfs.web.authentication.kerberos.keytab=!remove" \
                "HDFS-SITE.XML_dfs.data.transfer.protection=!remove" \
                "HDFS-SITE.XML_dfs.block.access.token.enable=false" \
                "CORE-SITE.XML_hadoop.rpc.protection=!remove" \
                "CORE-SITE.XML_hadoop.security.authorization=false" \
                envtoxml "${HADOOP_ETC}/${f}"
            ;;
        *)
            set -- envtoxml "${HADOOP_ETC}/${f}"
            ;;
    esac
    if ! "$@"; then
        echo "FATAL: envtoxml failed on ${HADOOP_ETC}/${f}" >&2
        exit 1
    fi
    unset --
done

# Clean up now: the script ends with `exec /init`, and exec does not
# fire the EXIT trap registered above, so the tempdir would otherwise
# leak on the happy path. (The trap still covers failures before this
# point.)
rm -rf "${TMPDIR_ENT}"

# ---------------------------------------------------------------------------
# Kerberos-only: KDC bootstrap, service principals + keytab, and the
# self-signed HTTPS keystore. In simple auth mode (HADOOP_SECURITY_
# AUTHENTICATION=Simple) none of this is needed — there is no realm DB,
# no SASL principal, and `dfs.http.policy=HTTP_ONLY` (set by the
# smoke-test's mount-override hdfs-site.xml) tells Hadoop not to load
# the keystore anyway, so a missing keystore is harmless. The XML
# configs and hadoop-env.sh below are mode-agnostic.
# ---------------------------------------------------------------------------
case "${HADOOP_SECURITY_AUTHENTICATION}" in
    [Ss]imple)
        echo "=== HADOOP_SECURITY_AUTHENTICATION=${HADOOP_SECURITY_AUTHENTICATION}: skipping KDC bootstrap + keytab + keystore ==="
        ;;
    *)
        # -------------------------------------------------------------------
        # KDC bootstrap
        # -------------------------------------------------------------------
        echo "=== Bootstrapping KDC if needed ==="
        mkdir -p /var/lib/krb5kdc /etc/krb5kdc /var/log/krb5

        # kdc.conf is the realm database config (separate from krb5.conf
        # which is the client-side config).
        cat > /etc/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_listen = 88
    kdc_tcp_listen = 88

[realms]
    ${KRB5_REALM} = {
        kadmin_port = 749
        max_life = 12h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = aes256-cts
        supported_enctypes = aes256-cts:normal aes128-cts:normal
        default_principal_flags = +preauth
    }

[logging]
    kdc = FILE:/var/log/krb5/krb5kdc.log
    admin_server = FILE:/var/log/krb5/kadmin.log
    default = FILE:/var/log/krb5/krb5lib.log
EOF

        # /var/lib/krb5kdc needs a symlink for krb5kdc to find its config
        # on some distros.
        [ -e /var/lib/krb5kdc/kdc.conf ] || ln -s /etc/krb5kdc/kdc.conf /var/lib/krb5kdc/kdc.conf

        # ACL: full admin via */admin@REALM, read-only for */service@REALM.
        cat > /etc/krb5kdc/kadm5.acl <<EOF
*/admin@${KRB5_REALM}    *
*/service@${KRB5_REALM}  aci
EOF
        [ -e /var/lib/krb5kdc/kadm5.acl ] || ln -s /etc/krb5kdc/kadm5.acl /var/lib/krb5kdc/kadm5.acl

        # Generate master/admin password if not supplied. We use
        # /dev/urandom for CSPRNG-quality entropy; bash's $RANDOM only
        # provides 15 bits (0-32767) and is brute-forceable in
        # milliseconds once the rough container start time is known.
        # /dev/urandom on Linux is a non-blocking CSPRNG seeded from the
        # kernel entropy pool and is appropriate for cryptographic key
        # material like the KDC master key.
        #
        # Pipeline:
        #   head -c 48 /dev/urandom  → 48 bytes = 384 bits of entropy
        #   base64                     → 64 base64 chars (6 bits each)
        #   tr -dc 'A-Za-z0-9_'        → filter to our 63-char alphabet
        #   ${var:0:32}                → take the first 32 chars (~190 bits)
        #
        # Note on SIGPIPE: the prior implementation used a pure-bash
        # $RANDOM loop specifically to avoid `tr | head -c N` triggering
        # SIGPIPE in tr (exit 141) under `set -o pipefail`. The pipeline
        # above side-steps that by capturing tr's full output via command
        # substitution and truncating in pure-bash parameter expansion
        # after the subshell exits. No `tr | head` boundary means no
        # SIGPIPE.
        if [ -z "${KRB5_PASS}" ]; then
            # Try to recover the password from the volume first.
            # The principal DB at /var/lib/krb5kdc/principal is
            # encrypted with KRB5_PASS, so the password must match
            # what was used to create the DB or every kadmin.local
            # call will fail to authenticate. We persist KRB5_PASS
            # to /var/lib/krb5kdc/.krb5_pass (inside the volume,
            # not the image's writable delta — the delta is reset
            # on `docker rm` + recreate, which would otherwise
            # generate a fresh password that can't decrypt the
            # surviving DB).
            #
            # Resolution order:
            #   1. Volume has the file → read it. The DB was
            #      created with this password; using it again
            #      keeps DB + kadmin auth consistent across
            #      container recreate cycles.
            #   2. Volume is empty (no DB, no .krb5_pass) → auto-
            #      generate, write to the volume, init DB. First
            #      boot only.
            #   3. Volume has the DB but no .krb5_pass (e.g. user
            #      wiped the file) → auto-gen and warn. The DB
            #      becomes unreadable until the user restores
            #      from a known-good password; this is the same
            #      posture as `docker compose down -v` (volume
            #      dropped, fresh realm), so the entrypoint
            #      intentionally does NOT try to "fix" a half-
            #      surviving volume.
            if [ -r /var/lib/krb5kdc/.krb5_pass ]; then
                KRB5_PASS=$(cat /var/lib/krb5kdc/.krb5_pass)
                echo "=== KRB5_PASS not set; recovered from /var/lib/krb5kdc/.krb5_pass (KDC volume) ==="
            else
                KRB5_PASS=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9_')
                KRB5_PASS="${KRB5_PASS:0:32}"
                # Write to a root-only file rather than echoing —
                # KRB5_PASS is the KDC master/admin password,
                # plaintext to docker logs is a credential leak.
                # Mode 0600 root:root keeps the credential out of
                # reach of the hdfs user. Operators retrieve with
                #   docker exec hdfs cat /var/lib/krb5kdc/.krb5_pass
                # (the smoke test reads it the same way).
                install -m 0600 -o root -g root /dev/null /var/lib/krb5kdc/.krb5_pass
                printf '%s' "${KRB5_PASS}" > /var/lib/krb5kdc/.krb5_pass
                echo "=== KRB5_PASS not set; generated and stored at /var/lib/krb5kdc/.krb5_pass (mode 0600, root, in the KDC volume) ==="
                if [ -f /var/lib/krb5kdc/principal ]; then
                    echo "=== WARNING: /var/lib/krb5kdc/principal exists but .krb5_pass is missing ===" >&2
                    echo "===   The existing KDC database is encrypted with a password we don't have; ===" >&2
                    echo "===   kdb5_util / kadmin.local will fail until the volume is restored from ===" >&2
                    echo "===   a known-good backup or wiped (`docker compose down -v`) for a fresh realm. ===" >&2
                fi
            fi
        fi

        # Initialize the realm database on first boot only. A populated
        # database contains the file /var/lib/krb5kdc/principal.
        if [ ! -f /var/lib/krb5kdc/principal ]; then
            echo "=== No KDC database found; creating realm ${KRB5_REALM} ==="

            # kdb5_util reads the master password from stdin twice.
            KRB5_TMP=$(mktemp)
            printf "%s\n%s\n" "${KRB5_PASS}" "${KRB5_PASS}" > "${KRB5_TMP}"
            kdb5_util create -r "${KRB5_REALM}" -s < "${KRB5_TMP}"
            rm -f "${KRB5_TMP}"

            # The KDC master key stash file is written by
            # `kdb5_util create -s` to a path decided at MIT build
            # time — on Debian/Ubuntu it lands in /etc/krb5kdc/
            # (the image's writable delta, NOT the volume). Without
            # this stash kadmin.local cannot decrypt the master
            # key from the principal DB, and on `docker rm` +
            # recreate the delta is reset so every kadmin.local
            # call after recreate fails with "Can not fetch master
            # key". Move it into the KDC volume alongside the DB
            # and symlink the canonical path so krb5kdc / kadmind
            # / kadmin.local all keep finding it.
            STASH_NAME=".k5.${KRB5_REALM}"
            if [ -f "/etc/krb5kdc/${STASH_NAME}" ] && [ ! -e "/var/lib/krb5kdc/${STASH_NAME}" ]; then
                mv "/etc/krb5kdc/${STASH_NAME}" "/var/lib/krb5kdc/${STASH_NAME}"
                ln -s "/var/lib/krb5kdc/${STASH_NAME}" "/etc/krb5kdc/${STASH_NAME}"
                echo "=== Moved master key stash to /var/lib/krb5kdc/${STASH_NAME} (in the KDC volume) ==="
            fi

            echo "=== Creating admin principal admin/admin@${KRB5_REALM} ==="
            KRB5_TMP=$(mktemp)
            printf "addprinc -pw %s admin/admin@%s\n" "${KRB5_PASS}" "${KRB5_REALM}" > "${KRB5_TMP}"
            kadmin.local < "${KRB5_TMP}"
            rm -f "${KRB5_TMP}"
        else
            echo "=== KDC database exists; skipping init ==="

            # Re-link the stash file on every boot in case the
            # image's writable delta was reset (docker rm + recreate)
            # but the volume (with both the principal DB and the
            # stash file we moved there on first boot) survived.
            # Without this symlink kadmin.local / kadmind report
            # "Can not fetch master key (error: No such file or
            # directory)" because they're hardcoded to look in
            # /etc/krb5kdc/.k5.REALM (Debian's MIT build default).
            STASH_NAME=".k5.${KRB5_REALM}"
            if [ ! -e "/etc/krb5kdc/${STASH_NAME}" ] && [ -e "/var/lib/krb5kdc/${STASH_NAME}" ]; then
                ln -s "/var/lib/krb5kdc/${STASH_NAME}" "/etc/krb5kdc/${STASH_NAME}"
                echo "=== Re-linked master key stash ${STASH_NAME} (volume → /etc/krb5kdc) ==="
            fi
        fi

        # -------------------------------------------------------------------
        # Service principals + keytab
        #
        # Re-issued on every boot (idempotent: kadmin treats an existing
        # principal as a no-op for addprinc -randkey). The HTTP principal
        # is needed for the NameNode Web UI HTTPS handler; testuser is
        # included for client smoke tests.
        # -------------------------------------------------------------------
        echo "=== Creating service principals + keytab ==="
        mkdir -p /etc/hadoop

        # IMPORTANT: feed each kadmin.local call its own stdin. When the
        # batch file is piped to kadmin.local via `kadmin.local < file`,
        # kadmin.local still runs the "Authenticating as principal
        # root/admin@REALM" step and reads its password prompt from the
        # same stdin. The first line of the batch (`addprinc -randkey
        # hdfs/...`) gets consumed as the password, and the `addprinc -pw
        # testpass testuser@REALM` line is then mis-parsed — the
        # principal is created but its password is silently dropped, so
        # `kinit testuser@REALM` rejects the password. Issuing each
        # operation as its own `kadmin.local -q` call gives every
        # invocation a clean argv and avoids the stdin/password
        # collision.
        #
        # `-randkey` for service principals (no password), then a
        # separate `-q addprinc -pw` for the interactive testuser.
        #
        # `-norandkey` on ktadd: by default `ktadd` re-keys the
        # principal (assigns a new random key and increments kvno),
        # which silently invalidates the password we just set with
        # `addprinc -pw`. With `-norandkey` we only export the existing
        # key to the keytab and leave the password intact.
        kadmin.local -q "addprinc -randkey hdfs/${HDFS_HOSTNAME}@${KRB5_REALM}"   >/dev/null
        kadmin.local -q "addprinc -randkey HTTP/${HDFS_HOSTNAME}@${KRB5_REALM}"  >/dev/null
        kadmin.local -q "addprinc -pw ${KRB5_TESTUSER_PASS} testuser@${KRB5_REALM}"           >/dev/null
        kadmin.local -q "ktadd -norandkey -k ${KEYTAB} hdfs/${HDFS_HOSTNAME}@${KRB5_REALM}"  >/dev/null
        kadmin.local -q "ktadd -norandkey -k ${KEYTAB} HTTP/${HDFS_HOSTNAME}@${KRB5_REALM}" >/dev/null
        # testuser is a password principal (smoke test does `kinit
        # testuser` with password testpass), so it deliberately has no
        # keytab entry.

        # Both namenode and datanode run as the hdfs user and need to
        # read the keytab.
        chown hdfs:hdfs "${KEYTAB}"
        chmod 0640 "${KEYTAB}"

        # -------------------------------------------------------------------
        # Self-signed keystore for HTTPS handlers.
        # CN must match the kerberos principal hostname for handlers
        # that verify peer names.
        # -------------------------------------------------------------------
        echo "=== Generating self-signed keystore ==="
        keytool -genkey -alias hdfs -keyalg RSA -keysize 2048 \
            -keystore "${KEYSTORE}" \
            -dname "CN=${HDFS_HOSTNAME}" \
            -storepass "${KEYSTORE_PASS}" -keypass "${KEYSTORE_PASS}" \
            -noprompt -validity 3650
        chown hdfs:hdfs "${KEYSTORE}"
        chmod 0640 "${KEYSTORE}"
        ;;
esac

# Hadoop needs to know the keystore credentials; the HDFS service
# config files reference the path but expect hadoop-env.sh exports
# for the passwords.
#
# Idempotent: a naive `>> file` would re-append on every container
# restart, leaving the file with N×3 duplicate lines after N
# restarts (functionally harmless — last value wins in shell — but
# unbounded growth on the persistent /opt/hadoop volume). Instead
# we first strip any prior lines matching our variable names, then
# append a single fresh copy. This also self-heals instances that
# were already running the buggy version.
sed -i \
    -e '/^export JAVA_HOME=/d' \
    -e '/^export HDFS_NAMENODE_USER=/d' \
    -e '/^export HDFS_DATANODE_USER=/d' \
    -e '/^export HDFS_SECONDARYNAMENODE_USER=/d' \
    -e '/^export HADOOP_OPTS=/d' \
    -e '/^export HADOOP_HDFS_HOME=/d' \
    -e '/^export HDFS_KEYSTORE_PATH=/d' \
    -e '/^export HDFS_KEYSTORE_PASS=/d' \
    "${HADOOP_ETC}/hadoop-env.sh"
{
    # The first 5 were previously appended in the Dockerfile at build
    # time; moved here so the two Dockerfiles (debian/ubuntu) share
    # one source of truth and the in-image hadoop-env.sh is rebuilt
    # idempotently on every container start. JAVA_HOME comes from
    # the Docker ENV (set by both Dockerfiles to a per-arch-stable
    # path); the rest are static hadoop-required values.
    printf '\nexport JAVA_HOME=%s\n' "${JAVA_HOME}"
    printf 'export HDFS_NAMENODE_USER=hdfs\n'
    printf 'export HDFS_DATANODE_USER=hdfs\n'
    printf 'export HDFS_SECONDARYNAMENODE_USER=hdfs\n'
    printf 'export HADOOP_OPTS="-Djava.security.krb5.conf=/etc/krb5.conf"\n'
    printf 'export HADOOP_HDFS_HOME=%s\n' "${HADOOP_HOME}"
    # HDFS_KEYSTORE_PATH/PASS only get written when the keystore
    # was actually generated — i.e. kerberos mode. In simple mode
    # the file pointed at by ${KEYSTORE} does NOT exist, and
    # Hadoop is supposed to skip the keystore because the
    # simple-mode auto-strip sets dfs.http.policy=HTTP_ONLY. But
    # writing a path to a nonexistent file into hadoop-env.sh
    # is a footgun: if an operator later flips dfs.http.policy
    # to HTTPS_ONLY (via -e HDFS-SITE.XML_dfs.http.policy=…)
    # without realizing the keystore was never generated, Hadoop
    # fails to start with a confusing FileNotFoundException. Keep
    # the in-image env contract honest by only emitting the vars
    # when the keystore actually exists (issue 3).
    if [ -f "${KEYSTORE}" ]; then
        printf 'export HDFS_KEYSTORE_PATH=%s\n' "${KEYSTORE}"
        printf 'export HDFS_KEYSTORE_PASS=%s\n' "${KEYSTORE_PASS}"
    fi
} >> "${HADOOP_ETC}/hadoop-env.sh"

# ---------------------------------------------------------------------------
# Make sure hadoop user/data dirs are present with right ownership.
# /var/lib/hadoop/namenode and /var/lib/hadoop/datanode are created
# on first boot by hdfs commands, but we mkdir them so the
# chown below works even if HDFS hasn't run yet.
#
# Only chown the dirs the hdfs user actually writes to — NOT the
# entire /opt/hadoop tree (which is a 600MB+ Hadoop distribution
# extracted from the upstream tarball, owned upstream by uid 1001).
# A recursive chown -R over that tree is ~10s of cold-start wall
# clock per container start. The hdfs user only needs write access
# to /opt/hadoop/logs (for hadoop daemon logs) and the data dirs;
# everything else (bin, lib, etc, share) is read-only for hdfs and
# root-owned is fine.
# ---------------------------------------------------------------------------
mkdir -p /var/lib/hadoop/namenode /var/lib/hadoop/datanode /opt/hadoop/logs
chown hdfs:hdfs \
    /var/lib/hadoop \
    /var/lib/hadoop/namenode \
    /var/lib/hadoop/datanode \
    /opt/hadoop/logs

# ---------------------------------------------------------------------------
# Hand off to s6-overlay.
# ---------------------------------------------------------------------------
echo "=== Handing off to s6-overlay ==="
exec /init
