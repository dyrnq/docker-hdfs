#!/usr/bin/env bash
# End-to-end smoke test for dyrnq/hdfs.
#
# Brings up a single container with KDC + NameNode + DataNode and
# exercises the cluster under one of two auth modes:
#
#   kerberos (default)
#       The image's normal entrypoint runs: KDC bootstraps,
#       service + testuser principals are created, the hdfs
#       keytab is generated, NameNode + DataNode kinit and
#       authenticate over SASL. The test exercises
#       dfsadmin -report, kinit, and a put/cat round trip.
#
#   simple
#       The image is kerberos-only by design — there's no Simple
#       config template baked in. To exercise the
#       hadoop.security.authentication=Simple code path we run the
#       same entrypoint but pass HADOOP_SECURITY_AUTHENTICATION=simple
#       — that tells docker-entrypoint.sh to skip KDC bootstrap +
#       keytab + keystore generation, strip the krb5kdc + kadmind
#       s6 services, and let the namenode + datanode longruns come
#       up unauthenticated. We then drive the in-image kerberos
#       template toward Simple-auth shape via envtoxml env vars —
#       one overwrite (block.access.token.enable=false +
#       hadoop.security.authorization=false) plus eight `!remove`
#       sentinels for the kerberos-only properties (keytabs, SPNs,
#       rpc-protection). This is the same path any user would
#       take to deploy Simple auth from this image, so smoke
#       doubles as the documented recipe. The s6 longruns come up
#       with the env-rendered XMLs and the hdfs commands run as
#       the hdfs user with no kinit. The test still exercises
#       dfsadmin -report and a put/cat round trip, plus assertions
#       that all the !remove / overwrite env vars actually
#       landed.
#
# Usage:
#   ./scripts/smoke-test.sh                          # kerberos (default)
#   ./scripts/smoke-test.sh kerberos
#   ./scripts/smoke-test.sh simple
#   ./scripts/smoke-test.sh kdc-only
#   ./scripts/smoke-test.sh datanode-only
#   MODE=simple ./scripts/smoke-test.sh
#   IMAGE=dyrnq/hdfs:latest-ubuntu ./scripts/smoke-test.sh
#
# Modes:
#   kerberos  — HDFS_SERVICES=namenode,datanode,krb5kdc,kadmind (default).
#               Full cluster with KDC; the canonical deployment.
#   simple    — HADOOP_SECURITY_AUTHENTICATION=simple, which the
#               entrypoint translates to HDFS_SERVICES=namenode,datanode.
#               No KDC, no keytab; the entrypoint auto-strips the
#               kerberos XML properties.
#   kdc-only  — HDFS_SERVICES=krb5kdc,kadmind. Only the KDC comes up;
#               no NN, no DN. Exercises the HDFS_SERVICES isolation
#               path in the entrypoint — proves a container can run
#               JUST the KDC for keytab distribution to other pods,
#               even though namenode/datanode longruns are not started.
#   datanode-only — HDFS_SERVICES=datanode (no namenode, no KDC). The
#               entrypoint MUST NOT FATAL on this; s6-rc-compile must
#               accept it (the dynamic dep build creates no edges
#               since namenode is missing); the DN run script's
#               hdfs_wait_for_namenode is expected to time out (no NN
#               to talk to) and s6 will mark the service down. The
#               test passes as long as the container itself stays up
#               long enough for s6 to mark the service down — i.e.
#               the entrypoint did not block startup.
#   mount-ro   — bind-mount a host XML at :ro + pass envtoxml env
#               vars. The entrypoint must (a) NOT clobber the
#               operator's XML (cp-back skipped), (b) NOT merge env
#               vars into it (envtoxml skipped). Asserts both by
#               comparing container's XML byte-for-byte to the host
#               file and verifying env vars did NOT land.
#   mount-rw   — same as mount-ro but :rw. Regression test for the
#               previous `[ ! -w ]`-only guard bug (which let the
#               entrypoint clobber operator XMLs on :rw mounts). The
#               new `is_xml_overridden()` catches both via
#               `mountpoint -q`. Verifies the operator's XML survives.
#   disable-envtoxml — HDFS_DISABLE_ENVTOXML=1. The entrypoint must
#               render the heredoc + apply sed placeholder substitution
#               but skip envtoxml entirely. Env vars must NOT land.
#               Also verifies the entrypoint's loud WARN about the
#               simple-mode interaction (auto-strip is implemented
#               inside envtoxml, so disabling it in simple mode
#               leaves kerberos-only properties in the XML).
#   empty     — HDFS_SERVICES= (explicit empty). The entrypoint must
#               accept this layout (no FATAL), s6-rc-compile must
#               accept an empty user bundle, and the container must
#               stay up indefinitely. Verifies no longruns start
#               (no ports bound) and the entrypoint log shows the
#               empty value (not a substituted default).
set -euo pipefail

# Args: <mode> [image]
# Env:  MODE= MODE= IMAGE=
# Positional mode wins over env; positional image falls back to env
# then to the debian default.
MODE="${1:-${MODE:-kerberos}}"
case "${MODE}" in
    kerberos|simple|kdc-only|datanode-only|mount-ro|mount-rw|disable-envtoxml|empty) ;;
    *) echo "FAIL: unknown mode '${MODE}' (want: kerberos|simple|kdc-only|datanode-only|mount-ro|mount-rw|disable-envtoxml|empty)"; exit 2 ;;
esac
shift || true
IMAGE="${1:-${IMAGE:-dyrnq/hdfs:latest-debian}}"
HOST="${HDFS_HOSTNAME:-hdfs.test}"
REALM="${KRB5_REALM:-TEST.LOCAL}"
NET="hdfs-smoke-net-$$"
SERVER="hdfs-smoke-$$"
KRB5_PASS=""
# mount-ro / mount-rw create a host tmpdir with a sentinel XML;
# tracked here so cleanup() removes it on exit.
SMOKE_TMPDIR=""

cleanup() {
    docker rm -f "$SERVER" 2>/dev/null || true
    docker network rm "$NET" 2>/dev/null || true
    if [ -n "${SMOKE_TMPDIR}" ] && [ -d "${SMOKE_TMPDIR}" ]; then
        rm -rf "${SMOKE_TMPDIR}"
    fi
}
trap cleanup EXIT

echo "=== Image: $IMAGE ==="
echo "=== Mode:   $MODE ==="
echo "=== Hostname: $HOST / Realm: $REALM ==="

echo "=== Creating docker network ==="
docker network create "$NET" >/dev/null

if [ "$MODE" = "kerberos" ]; then
    # Standard launch: let the entrypoint bootstrap KDC, principals,
    # keytab, and the hadoop XML configs.
    #
    # The envtoxml feature is exercised here too: the kerberos-mode
    # XML at /opt/hadoop/etc/hadoop/hdfs-site.xml is the image's own
    # copy (writable), so envtoxml runs and the overrides land. We
    # pick three properties that exercise all three code paths —
    # append (new key), overwrite (existing key, different value),
    # and !remove (existing key, sentinel value) — and that are safe
    # to mutate without breaking the kerberos auth path:
    #   dfs.client.use.datanode.hostname=true  → new key (append)
    #   dfs.replication=2                       → exists as 1 → overwrite
    #   dfs.namenode.secondary.http-address     → exists → !remove
    #     (no SecondaryNameNode runs here, removing it is a no-op)
    # See the envtoxml block below for the in-container verification.
    echo "=== Starting container (kerberos) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e KRB5_REALM="$REALM" \
        -e KRB5_KDC="$HOST" \
        -e "KRB5_TESTUSER_PASS=${KRB5_TESTUSER_PASS:-testpass}" \
        -e "HDFS-SITE.XML_dfs.client.use.datanode.hostname=true" \
        -e "HDFS-SITE.XML_dfs.replication=2" \
        -e "HDFS-SITE.XML_dfs.namenode.secondary.http-address=!remove" \
        "$IMAGE"
elif [ "$MODE" = "kdc-only" ]; then
    # KDC-only launch: pin HDFS_SERVICES to krb5kdc,kadmind and let
    # HADOOP_SECURITY_AUTHENTICATION default to kerberos. The
    # entrypoint's HDFS_SERVICES block (1) rebuilds contents.d/ so
    # the s6 longruns for namenode + datanode are NEVER started and
    # (2) cleans up the dangling `namenode→krb5kdc` and `datanode→
    # namenode` edges (no NN = nothing for DN to depend on, no KDC-
    # free mode = no KDC for NN to wait for). The KDC bootstrap
    # still runs because HADOOP_SECURITY_AUTHENTICATION=kerberos
    # gates that block separately. The point of this mode is to
    # prove the isolation: a single container that boots ONLY a
    # KDC, so other pods in the deployment can kinit against it
    # for keytab distribution. We pass no Hadoop-related env vars
    # — the test relies on the entrypoint's defaults for the
    # realm/hostname/ports.
    echo "=== Starting container (kdc-only: HDFS_SERVICES=krb5kdc,kadmind) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HDFS_SERVICES=krb5kdc,kadmind \
        "$IMAGE"
elif [ "$MODE" = "datanode-only" ]; then
    # Single-service start: HDFS_SERVICES=datanode, with simple
    # auth so the DN's kinit is skipped. The point of this mode
    # is to prove the entrypoint does NOT FATAL on a partial
    # layout (no namenode, no KDC) and that s6-rc-compile
    # accepts the dep graph (no edges get created because the
    # targets — namenode, krb5kdc — are missing). The DN run
    # script will then time out on hdfs_wait_for_namenode (no
    # NN to register with); we don't try to make the DN happy,
    # we just verify the entrypoint + s6-rc-compile path. The
    # container stays up; the DN service is marked down by s6.
    echo "=== Starting container (datanode-only: HDFS_SERVICES=datanode) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HDFS_SERVICES=datanode \
        -e HADOOP_SECURITY_AUTHENTICATION=simple \
        "$IMAGE"
elif [ "$MODE" = "mount-ro" ]; then
    # Mount-A: operator binds their own hdfs-site.xml :ro. The
    # entrypoint must (a) NOT clobber the operator's file (cp-back
    # skipped via is_xml_overridden), (b) NOT merge envtoxml env
    # vars into it. We prove both by checking byte-identity with
    # the host file AND checking that an env var with a sentinel
    # value did NOT land.
    #
    # The host XML is intentionally small + atypical (no
    # kerberos, no bind-host fixes). If the entrypoint clobbered
    # it, the heredoc's 25+ properties would suddenly appear and
    # the byte-identity check would fail.
    #
    # HADOOP_SECURITY_AUTHENTICATION=simple keeps the test
    # hermetic — no KDC, no SASL, no keytab generation.
    echo "=== Starting container (mount-ro: bind-mount hdfs-site.xml:ro + envtoxml env vars) ==="
    SMOKE_TMPDIR=$(mktemp -d)
    cat > "${SMOKE_TMPDIR}/hdfs-site.xml" <<'EOF'
<?xml version="1.0"?>
<configuration>
    <property><name>dfs.replication</name><value>7</value></property>
    <property><name>dfs.namenode.rpc-address</name><value>my-nn.example.com:8020</value></property>
    <property><name>smoke.test.marker</name><value>HOST_FILE_RO</value></property>
</configuration>
EOF
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HADOOP_SECURITY_AUTHENTICATION=simple \
        -v "${SMOKE_TMPDIR}/hdfs-site.xml:/opt/hadoop/etc/hadoop/hdfs-site.xml:ro" \
        -e "HDFS-SITE.XML_dfs.replication=999" \
        -e "HDFS-SITE.XML_smoke.test.envvar=SHOULD_NOT_LAND" \
        "$IMAGE"
elif [ "$MODE" = "mount-rw" ]; then
    # Mount-B: same as mount-ro but :rw. Regression test for the
    # previous `[ ! -w ]`-only guard bug, which let the
    # entrypoint's `cp -f` clobber operator XMLs on :rw mounts
    # (`:rw` IS writable so `[ ! -w ]` returned 1 = "not
    # overridden", and the heredoc render got written over the
    # operator's file). The fix is `is_xml_overridden()` checking
    # `mountpoint -q` first, which catches bind-mounts regardless
    # of writability. This mode proves the fix.
    #
    # Critical: the verification checks that the host file's
    # CONTENT survived — i.e. `dfs.replication=7` (host) not =1
    # (heredoc). If the entrypoint clobbered, the byte-identity
    # check would fail (heredoc has 25+ props; host has 3).
    echo "=== Starting container (mount-rw: bind-mount hdfs-site.xml:rw + envtoxml env vars) ==="
    SMOKE_TMPDIR=$(mktemp -d)
    cat > "${SMOKE_TMPDIR}/hdfs-site.xml" <<'EOF'
<?xml version="1.0"?>
<configuration>
    <property><name>dfs.replication</name><value>7</value></property>
    <property><name>smoke.test.marker</name><value>HOST_FILE_RW</value></property>
</configuration>
EOF
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HADOOP_SECURITY_AUTHENTICATION=simple \
        -v "${SMOKE_TMPDIR}/hdfs-site.xml:/opt/hadoop/etc/hadoop/hdfs-site.xml:rw" \
        -e "HDFS-SITE.XML_dfs.replication=999" \
        "$IMAGE"
elif [ "$MODE" = "disable-envtoxml" ]; then
    # Mount-C: HDFS_DISABLE_ENVTOXML=1. The entrypoint must render
    # the heredoc + apply sed placeholder substitution, but skip
    # the envtoxml pass entirely. Env vars must NOT land.
    #
    # Side effect to be aware of: HADOOP_SECURITY_AUTHENTICATION=
    # simple means the entrypoint WOULD auto-strip the kerberos
    # properties via envtoxml. Disabling envtoxml in simple mode
    # leaves them in place, which is a known interaction (issues
    # #13/#14 design). The entrypoint prints a loud WARN for this
    # combination; we assert that WARN is logged. The kerberos-
    # only properties staying in the XML is expected behavior,
    # NOT a failure — the test only requires the env vars NOT
    # land and the WARN to be present.
    #
    # Note: no hdfs dfs round-trip in this mode — the NN/DN would
    # fail to start (kinit has nowhere to go), and that's the
    # expected outcome. We just verify the entrypoint + XML
    # rendering branches, then exit.
    echo "=== Starting container (disable-envtoxml: HDFS_DISABLE_ENVTOXML=1) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HADOOP_SECURITY_AUTHENTICATION=simple \
        -e HDFS_DISABLE_ENVTOXML=1 \
        -e "HDFS-SITE.XML_dfs.replication=999" \
        -e "HDFS-SITE.XML_smoke.test.envvar=SHOULD_NOT_LAND" \
        "$IMAGE"
elif [ "$MODE" = "empty" ]; then
    # Layout-A: HDFS_SERVICES= (explicit empty value). The
    # entrypoint must accept this without falling back to a
    # default — `: ${HDFS_SERVICES:=default}` substitutes on
    # empty values, so the old line at entrypoint:331 had to be
    # removed (the empty-profile support task #115). The
    # remaining `${VAR+set}` probe in the env-to-default block
    # handles "unset" correctly without clobbering "set to empty".
    #
    # Outcomes to verify:
    #   - container stays up (entrypoint didn't FATAL on empty)
    #   - s6-rc bundle has zero user services (4 services absent)
    #   - no longruns → no ports bound (88/464/8020/9870/9866/9864
    #     all unbound per /proc/net/tcp[6])
    #   - entrypoint log shows the literal empty value, NOT a
    #     substituted default
    #
    # Default HADOOP_SECURITY_AUTHENTICATION=kerberos means the
    # KDC bootstrap block still runs (gated on auth, not on
    # HDFS_SERVICES) and writes the realm DB + keytab to the
    # volume — that's expected, useful for the "bootstrap a KDC
    # volume, mount into another container" use case.
    echo "=== Starting container (empty: HDFS_SERVICES=) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HDFS_SERVICES= \
        "$IMAGE"
else
    # Simple auth launch: run the normal entrypoint but pass
    # HADOOP_SECURITY_AUTHENTICATION=simple so the entrypoint
    # (a) strips the krb5kdc + kadmind s6 services and (b) skips
    # KDC bootstrap + keytab + keystore. We still bind-mount our
    # Simple-auth XMLs so the rendered hadoop configs actually
    # carry Simple + HTTP_ONLY — the entrypoint reads them, sed-
    # applies (no-op for the Simple flag), and writes the same
    # content back. The mount override survives because the
    # entrypoint's `cp -f` writes to the host-mounted path.
    # Simple auth launch: no KDC, no keytab, no SPNs. Drive the
    # in-image kerberos template toward Simple-auth shape via
    # envtoxml env vars (one source of truth, no scripts/conf/
    # directory to keep in sync). Each var below corresponds to
    # a documented difference between the kerberos default and a
    # Simple-auth setup; together they form the recipe any user
    # can copy into a deployment. envtoxml's [ -w ] guard runs
    # because we don't bind-mount the XMLs, so the merges are
    # actually applied to /opt/hadoop/etc/hadoop/*.xml.
    #
    # The entrypoint's simple-mode branch auto-strips the kerberos
    # properties from hdfs-site.xml / core-site.xml (issues #13, #14)
    # — so we no longer need to pass the 11 `HDFS-SITE.XML_*` /
    # `CORE-SITE.XML_*` env vars. The smoke now exercises the
    # entrypoint path with a single env var
    # (HADOOP_SECURITY_AUTHENTICATION=simple), which is the
    # intended user-facing UX.
    echo "=== Starting container (simple, entrypoint auto-strip) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HADOOP_SECURITY_AUTHENTICATION=simple \
        "$IMAGE"
fi

# The KDC + KRB5_PASS path is shared by the kerberos and kdc-only modes
# (both run with HADOOP_SECURITY_AUTHENTICATION=kerberos, so the
# KDC bootstrap path runs in the entrypoint and the .krb5_pass file
# is written). In simple mode the KDC never comes up and the file
# does not exist, so this whole block is skipped.
if [ "$MODE" = "kerberos" ] || [ "$MODE" = "kdc-only" ]; then
    echo "=== Waiting for KDC (port 88) ==="
    for i in $(seq 1 60); do
        if docker exec "$SERVER" nc -z localhost 88 2>/dev/null; then
            echo "  KDC is up after ${i}s"
            break
        fi
        sleep 1
    done

    if ! docker exec "$SERVER" nc -z localhost 88 2>/dev/null; then
        echo "FAIL: KDC did not come up within 60s"
        docker logs "$SERVER"
        exit 1
    fi

    # Read the master/admin password from the entrypoint's drop
    # file. The entrypoint writes /var/lib/krb5kdc/.krb5_pass (mode
    # 0600 root:root, inside the KDC volume — same dir as the
    # encrypted principal DB) instead of echoing the password to
    # docker logs — plaintext credentials in `docker logs` is a
    # leak, and putting the file in the volume keeps the password
    # in sync with the DB across container recreate cycles.
    echo "=== Reading KRB5_PASS from /var/lib/krb5kdc/.krb5_pass ==="
    KRB5_PASS=$(docker exec "$SERVER" cat /var/lib/krb5kdc/.krb5_pass 2>/dev/null || true)
    if [ -z "$KRB5_PASS" ]; then
        echo "FAIL: could not read KRB5_PASS from /var/lib/krb5kdc/.krb5_pass"
        echo "  (the entrypoint writes this file on first boot regardless of whether"
        echo "   KRB5_PASS was env-supplied or auto-generated; missing file means the"
        echo "   entrypoint didn't run, or the volume was wiped without -v)"
        docker logs "$SERVER"
        exit 1
    fi
    echo "  KRB5_PASS length: ${#KRB5_PASS}"
fi

# ---------------------------------------------------------------------
# kdc-only mode short-circuits the rest of the script. The point of
# the mode is to prove HDFS_SERVICES isolation: a container that
# boots ONLY the KDC, with no NN/DN. Everything below this point is
# full-cluster verification (NN RPC, DN registration, dfsadmin, file
# round-trip) which is meaningless without a NameNode. We verify
# the three properties the mode is designed to exercise, then exit
# cleanly so the full-cluster assertions (which would otherwise
# time out waiting for an NN that was never started) don't fire.
# ---------------------------------------------------------------------
if [ "$MODE" = "kdc-only" ]; then
    echo "=== kdc-only verification (HDFS_SERVICES isolation) ==="

    # Authoritative state signal: `s6-rc -a list` enumerates the
    # services s6-rc currently knows about, which is exactly the
    # union of contents.d/ in the user bundle + the s6-overlay
    # internal services (s6rc-oneshot-runner, fix-attrs,
    # legacy-cont-init, legacy-services). Services the entrypoint
    # removed from contents.d/ (via the HDFS_SERVICES block) do
    # NOT appear here, even though their on-disk servicedirs at
    # /run/s6-rc/servicedirs/<name> still exist (s6-rc-compile
    # creates servicedirs for every compiled service, but only
    # those in the user bundle get symlinked at /run/service/<n>
    # AND brought up). /run/service/<n> is therefore NOT a reliable
    # signal of bundle membership — we have to ask s6-rc.
    #
    # s6-rc is at /command/s6-rc (s6-overlay 3.x doesn't put it on
    # PATH for `docker exec` shells; PATH is /opt/hadoop/bin:...:/bin
    # and s6 lives at /command/, only added by with-contenv).
    s6_bundle() {
        docker exec "$SERVER" /command/s6-rc -a list 2>/dev/null
    }

    BUNDLE=$(s6_bundle)
    if [ -z "$BUNDLE" ]; then
        echo "FAIL: 's6-rc -a list' returned no output; cannot verify isolation"
        docker logs "$SERVER"
        exit 1
    fi

    # (1) krb5kdc + kadmind must be in the user bundle. s6
    # internally tracks up/down state for started services via
    # s6-svstat (also at /command/), so we cross-check by
    # confirming no java/hadoop process is bound to the NN/DN
    # ports either.
    for svc in krb5kdc kadmind; do
        if ! echo "$BUNDLE" | grep -qx "$svc"; then
            echo "FAIL: kdc-only mode but '${svc}' is not in s6-rc bundle"
            echo "  bundle:"; echo "$BUNDLE" | sed 's/^/    /'
            exit 1
        fi
    done
    echo "  krb5kdc + kadmind: in s6-rc bundle"

    # (2) namenode + datanode must NOT be in the bundle. If
    # either shows up, the entrypoint's contents.d/ rebuild is
    # broken and the isolation regressed to "all 4 services" —
    # the worst-case failure mode (HDFS_SERVICES silently
    # ignored, the KDC runs alone AND an NN/DN also start).
    for svc in namenode datanode; do
        if echo "$BUNDLE" | grep -qx "$svc"; then
            echo "FAIL: kdc-only mode but '${svc}' IS in s6-rc bundle"
            echo "  HDFS_SERVICES isolation broken; bundle:"
            echo "$BUNDLE" | sed 's/^/    /'
            exit 1
        fi
    done
    echo "  namenode + datanode: not in s6-rc bundle (HDFS_SERVICES isolation ok)"

    # (3) Cross-check: no NameNode / DataNode processes. This
    # catches the case where the bundle is wrong but somehow
    # an NN got started out-of-band, OR the s6-svstat state
    # for a removed service is "up" because of a stale symlink.
    # The grep is broad on purpose (the run script invokes
    # `hdfs namenode` / `hdfs datanode` and the JVM class
    # names NameNode / DataNode both appear in `ps` output).
    PIDS=$(docker exec "$SERVER" sh -c \
        'ps -ef 2>/dev/null | grep -E "(org\.apache\.hadoop\.hdfs\.server\.(namenode|NameNode|datanode|DataNode)\.|hdfs (namenode|datanode))" | grep -v grep || true' 2>/dev/null)
    if [ -n "$PIDS" ]; then
        echo "FAIL: kdc-only mode but NameNode/DataNode process found"
        echo "$PIDS" | sed 's/^/    /'
        exit 1
    fi
    echo "  ps: no NameNode/DataNode processes"

    # (4) kinit testuser against the embedded KDC — proves the
    # KDC services not only started but actually answer AS
    # requests and will hand out a TGT. This is the meat of the
    # "KDC for keytab distribution" use case: an external pod
    # running kinit with `-t <keytab>` and a -c cache would
    # follow the same code path.
    KRB5_TESTUSER_PASS="${KRB5_TESTUSER_PASS:-testpass}"
    docker exec "$SERVER" bash -c "
        set -e
        printf '%s\n' \"\${KRB5_TESTUSER_PASS:-testpass}\" | kinit testuser@${REALM}
        klist
    "
    echo "  kinit testuser: TGT issued by embedded KDC"

    # (5) Negative check: hdfs dfs against the would-be NN RPC
    # port must fail. There is no NN, so dfs should error out
    # with a connection refused (or similar), NOT silently succeed
    # with a stale cluster. A 0 exit here means a DN/NN somehow
    # came up despite HDFS_SERVICES — i.e. the isolation regressed
    # to "all 4 services". Catching this is the whole point of
    # the mode.
    if docker exec "$SERVER" gosu hdfs /opt/hadoop/bin/hdfs \
        dfs -fs "hdfs://${HOST}:8020" -ls / 2>/dev/null; then
        echo "FAIL: kdc-only mode but hdfs dfs succeeded (NN should be down)"
        exit 1
    fi
    echo "  hdfs dfs: failed as expected (no NN running)"

    echo "=== SMOKE TEST PASSED (mode=${MODE}) ==="
    exit 0
fi

# ---------------------------------------------------------------------
# datanode-only mode short-circuits the rest of the script. The point
# of this mode is to prove the entrypoint's dynamic dep build accepts
# a partial layout (just datanode) without FATAL and that s6-rc-compile
# succeeds even with no namenode, no krb5kdc in the bundle. The DN
# longrun will then time out on hdfs_wait_for_namenode (no NN to talk
# to) and s6 will mark the service down — that's expected. We verify
# the four properties the mode is designed to exercise, then exit
# cleanly. The full-cluster assertions below (NN wait, dfsadmin,
# put/cat) would otherwise time out since there is no NN.
# ---------------------------------------------------------------------
if [ "$MODE" = "datanode-only" ]; then
    echo "=== datanode-only verification (dynamic dep build) ==="

    # Give the container a moment to settle: s6-rc-compile runs in
    # /init AFTER the entrypoint returns, and the DN longrun starts
    # only after that. If the entrypoint FATAL'd (e.g. on the
    # dynamic dep build), the container exits before s6 even
    # compiles the bundle. 10s is enough for s6-rc-compile to
    # finish on a 1-service bundle and for the DN longrun to start
    # and reach its first hdfs_wait_for_namenode call.
    sleep 10

    # (1) The container must still be RUNNING. If the entrypoint
    # crashed, the container exits and `docker ps` shows nothing.
    # This is the most fundamental assertion: the entrypoint did
    # not FATAL on a partial HDFS_SERVICES layout.
    if ! docker ps --format '{{.Names}}' | grep -qx "$SERVER"; then
        echo "FAIL: datanode-only mode but container is not running"
        echo "  (entrypoint FATAL'd on partial HDFS_SERVICES layout?)"
        docker logs "$SERVER" 2>/dev/null || true
        exit 1
    fi
    echo "  container: still running (entrypoint did not FATAL)"

    # (2) s6-rc bundle must contain only datanode among the 4
    # Hadoop services. krb5kdc + kadmind + namenode are absent.
    s6_bundle() {
        docker exec "$SERVER" /command/s6-rc -a list 2>/dev/null
    }
    BUNDLE=$(s6_bundle)
    if [ -z "$BUNDLE" ]; then
        echo "FAIL: 's6-rc -a list' returned no output"
        docker logs "$SERVER"
        exit 1
    fi
    if ! echo "$BUNDLE" | grep -qx "datanode"; then
        echo "FAIL: datanode-only mode but 'datanode' is not in s6-rc bundle"
        echo "  bundle:"; echo "$BUNDLE" | sed 's/^/    /'
        exit 1
    fi
    for svc in krb5kdc kadmind namenode; do
        if echo "$BUNDLE" | grep -qx "$svc"; then
            echo "FAIL: datanode-only mode but '${svc}' IS in s6-rc bundle"
            echo "  HDFS_SERVICES isolation broken; bundle:"
            echo "$BUNDLE" | sed 's/^/    /'
            exit 1
        fi
    done
    echo "  bundle: only datanode (krb5kdc + kadmind + namenode absent)"

    # (3) No NameNode / KDC / kadmind longrun is actually
    # RUNNING. Cross-check (2) — even though krb5kdc + kadmind
    # + namenode are not in the user bundle, s6-rc-compile still
    # creates servicedirs for them (compile keys off servicedir
    # existence, not bundle membership), and s6-svscan leaves
    # an `s6-supervise <name>` daemon attached to each
    # servicedir. So `ps -ef | grep s6-supervise` will list
    # krb5kdc + kadmind + namenode — that's normal and NOT a
    # sign those services are running. The reliable signal is
    # s6-svstat's "up" state, which goes "up" only AFTER the
    # service's run script forks the daemon. (s6-svstat
    # appears in the grep below as "s6-svstat" — we exclude
    # it explicitly.)
    #
    # s6-svstat output format: "up (pid N pgid M) Ts" or
    # "down (exitcode 0) Ts, ready Ts" or similar. We use awk
    # to extract just the first word.
    for svc in krb5kdc kadmind namenode; do
        state=$(docker exec "$SERVER" /command/s6-svstat "/run/service/${svc}" 2>/dev/null \
            | awk '{print $1; exit}' || true)
        if [ "$state" = "up" ]; then
            echo "FAIL: datanode-only mode but '${svc}' longrun is up"
            docker exec "$SERVER" /command/s6-svstat "/run/service/${svc}" 2>&1 | sed 's/^/    /'
            docker logs "$SERVER"
            exit 1
        fi
    done
    echo "  s6-svstat: krb5kdc + kadmind + namenode all down (longruns did NOT start)"

    # (4) Nothing is bound on the KDC (88) or kadmind (464)
    # ports. A second cross-check for (3) — even if s6-svstat
    # missed something, the kernel's port table is the
    # authoritative answer for "is anything answering?". We
    # use /proc/net/tcp[6] like the IPv4 listener check below,
    # since `nc -z` from busybox is unreliable (it can exit 0
    # for unbound ports on some configurations).
    PROC_TCP=$(docker exec "$SERVER" cat /proc/net/tcp 2>/dev/null || true)
    PROC_TCP6=$(docker exec "$SERVER" cat /proc/net/tcp6 2>/dev/null || true)
    FAIL_PORT=0
    for port in 88 464; do
        port_hex=$(printf '%04X' "$port")
        # IPv4 LISTEN (st=0A) on this port anywhere.
        v4=$(echo "$PROC_TCP" | awk -v p=":$port_hex" \
            '$2 ~ p"$" && $4 == "0A" {print $2; exit}')
        # IPv6 LISTEN, excluding the pure IPv6 wildcard.
        v6=$(echo "$PROC_TCP6" | awk -v p=":$port_hex" \
            '$2 ~ p"$" && $4 == "0A" && $2 !~ /^00000000000000000000000000000000:/ {print $2; exit}')
        if [ -n "$v4" ] || [ -n "$v6" ]; then
            echo "FAIL: port $port (0x$port_hex) has a LISTEN — KDC/kadmind should be down"
            FAIL_PORT=1
        fi
    done
    if [ "$FAIL_PORT" = "1" ]; then
        docker logs "$SERVER"
        exit 1
    fi
    echo "  ports: 88 (KDC) and 464 (kadmind) unbound"

    # (5) The datanode service is registered with s6-rc (proving
    # s6-rc-compile accepted the dep graph with no edges — the
    # entrypoint's dynamic dep build created no files in
    # datanode/dependencies.d/ because namenode was absent).
    # s6-svstat reports "up" for the DN because the run script
    # has entered hdfs_wait_for_namenode and is currently
    # polling hdfs dfsadmin (the DFSAdmin JVM visible in
    # `ps -ef`); the script as a whole is "up" from s6's
    # perspective. That's the EXPECTED state for a
    # datanode-only container — not a failure.
    DN_STATE=$(docker exec "$SERVER" /command/s6-svstat /run/service/datanode 2>/dev/null \
        | awk '{print $1; exit}' || true)
    if [ "$DN_STATE" != "up" ]; then
        echo "FAIL: datanode service is not 'up' (got '${DN_STATE:-unknown}')"
        docker exec "$SERVER" /command/s6-svstat /run/service/datanode 2>&1 | sed 's/^/    /'
        docker logs "$SERVER"
        exit 1
    fi
    echo "  datanode s6-svstat: up (waiting on hdfs_wait_for_namenode as expected)"

    echo "=== SMOKE TEST PASSED (mode=${MODE}) ==="
    exit 0
fi

# ---------------------------------------------------------------------
# mount-ro / mount-rw mode short-circuits. The point of these modes is
# to prove operator-mounted XMLs are preserved by the entrypoint (not
# clobbered by the heredoc render) AND that envtoxml does NOT mutate
# them. The full-cluster assertions below assume
# HDFS_SERVICES=namenode,datanode with the heredoc XML — irrelevant
# here.
# ---------------------------------------------------------------------
if [ "$MODE" = "mount-ro" ] || [ "$MODE" = "mount-rw" ]; then
    echo "=== ${MODE} verification (operator XML preserved + envtoxml skipped) ==="

    # The entrypoint runs synchronously and exits within a couple
    # of seconds. 5s is plenty for simple-mode + mount to converge
    # (no KDC, no NN/DN startup to wait for — the cluster
    # intentionally can't come up with a 3-property XML).
    sleep 5

    # (1) Container must still be RUNNING. If the entrypoint
    # FATAL'd (e.g. heredoc render broke, mountpoint -q rejected
    # the bind), the container exits.
    if ! docker ps --format '{{.Names}}' | grep -qx "$SERVER"; then
        echo "FAIL: ${MODE} mode but container is not running"
        docker logs "$SERVER" 2>/dev/null || true
        exit 1
    fi
    echo "  container: still running"

    # (2) Container's hdfs-site.xml must be byte-identical to
    # the host file. The entrypoint's is_xml_overridden() guard
    # must catch both :ro and :rw bind-mounts — the previous
    # `[ ! -w ]`-only guard missed :rw and would have clobbered
    # the operator's file via `cp -f`. We compare the full file
    # contents (not just one property) so a heredoc-render
    # overwriting the file is caught even if the marker happened
    # to match.
    HDFS_XML_CONTENT=$(docker exec "$SERVER" cat /opt/hadoop/etc/hadoop/hdfs-site.xml 2>/dev/null || true)
    if [ -z "$HDFS_XML_CONTENT" ]; then
        echo "FAIL: could not read container's hdfs-site.xml"
        docker logs "$SERVER"
        exit 1
    fi
    HOST_XML_CONTENT=$(cat "${SMOKE_TMPDIR}/hdfs-site.xml" 2>/dev/null || true)
    if [ "$HDFS_XML_CONTENT" != "$HOST_XML_CONTENT" ]; then
        echo "FAIL: container's hdfs-site.xml was mutated by entrypoint"
        echo "  --- container (len=${#HDFS_XML_CONTENT}):"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        echo "  --- host (len=${#HOST_XML_CONTENT}):"
        echo "$HOST_XML_CONTENT" | sed 's/^/    /'
        docker logs "$SERVER"
        exit 1
    fi
    echo "  container hdfs-site.xml == host hdfs-site.xml (byte-identical, no clobber)"

    # (3) Env var HDFS-SITE.XML_dfs.replication=999 must NOT have
    # mutated the XML. The host file has dfs.replication=7 and
    # the env var said =999; the rendered file must still say =7
    # AND must NOT contain =999 (envtoxml would have appended or
    # overwritten to =999).
    if ! echo "$HDFS_XML_CONTENT" | grep -q '<name>dfs.replication</name><value>7</value>'; then
        echo "FAIL: host XML's dfs.replication=7 was not preserved"
        echo "  envtoxml mutated operator XML or the file got clobbered:"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    if echo "$HDFS_XML_CONTENT" | grep -q '<value>999</value>'; then
        echo "FAIL: env var HDFS-SITE.XML_dfs.replication=999 landed in operator XML"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  env vars skipped: dfs.replication=7 (operator default, not env=999)"

    # (4) Mode-specific sentinel marker in the host file's
    # <value> tag. If the entrypoint clobbered the file with the
    # heredoc render, the marker would be gone (heredoc has no
    # smoke.test.marker property at all).
    if [ "$MODE" = "mount-ro" ]; then
        MARKER="HOST_FILE_RO"
    else
        MARKER="HOST_FILE_RW"
    fi
    if ! echo "$HDFS_XML_CONTENT" | grep -q "<value>${MARKER}</value>"; then
        echo "FAIL: sentinel marker '${MARKER}' missing from container XML"
        echo "  (entrypoint clobbered operator's XML with heredoc render?)"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  sentinel marker present: ${MARKER}"

    # (5) Verify the heredoc render did NOT run on the mounted
    # file. The heredoc has 25+ properties; the host file has 3.
    # If the heredoc render wrote to the bind-mounted path, we'd
    # see lots of kerberos / bind-host properties — none should
    # be present.
    if echo "$HDFS_XML_CONTENT" | grep -q 'dfs.namenode.kerberos.principal'; then
        echo "FAIL: heredoc render ran against operator's XML"
        echo "  (heredoc-only property dfs.namenode.kerberos.principal appeared)"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  heredoc render skipped: no heredoc-only properties in operator XML"

    # (6) For mount-rw only: verify the host file's mtime is
    # unchanged. The heredoc render would write via `cp -f` to
    # the bind-mounted path on :rw, updating mtime. A clean
    # mount should leave mtime alone. (skip on :ro — the
    # filesystem would refuse the write anyway and mtime is not
    # a meaningful check.)
    if [ "$MODE" = "mount-rw" ]; then
        # Wait briefly to ensure any write attempt has settled,
        # then stat both. The container's view of the file is
        # what matters; mtime differences > 2s indicate a write.
        sleep 2
        HOST_MTIME=$(stat -c %Y "${SMOKE_TMPDIR}/hdfs-site.xml" 2>/dev/null || stat -f %m "${SMOKE_TMPDIR}/hdfs-site.xml" 2>/dev/null || echo 0)
        # The container's view of the bind-mount's mtime should
        # match the host's mtime. If the entrypoint wrote to the
        # file, mtime would be NEWER on the host (because :rw
        # binds go through the host's filesystem for writes).
        CONT_MTIME=$(docker exec "$SERVER" stat -c %Y /opt/hadoop/etc/hadoop/hdfs-site.xml 2>/dev/null \
            || docker exec "$SERVER" stat -f %m /opt/hadoop/etc/hadoop/hdfs-site.xml 2>/dev/null \
            || echo 0)
        if [ "$HOST_MTIME" = "0" ] || [ "$CONT_MTIME" = "0" ]; then
            echo "WARN: could not stat mtime (HOST=$HOST_MTIME CONT=$CONT_MTIME); skipping mtime check"
        elif [ "$CONT_MTIME" -gt "$((HOST_MTIME + 2))" ]; then
            echo "FAIL: container's mtime (${CONT_MTIME}) > host's mtime (${HOST_MTIME})"
            echo "  (entrypoint wrote to the bind-mounted file despite is_xml_overridden guard)"
            docker logs "$SERVER"
            exit 1
        else
            echo "  mtime: host=${HOST_MTIME} container=${CONT_MTIME} (consistent, no writes)"
        fi
    fi

    echo "=== SMOKE TEST PASSED (mode=${MODE}) ==="
    exit 0
fi

# ---------------------------------------------------------------------
# disable-envtoxml mode short-circuits. The point is to prove
# HDFS_DISABLE_ENVTOXML=1 makes the entrypoint skip envtoxml (env vars
# don't land) while still rendering the heredoc + sed substitution.
# The full-cluster assertions below assume NN + DN + dfsadmin — those
# won't come up in this mode because the simple-mode auto-strip didn't
# run (envtoxml was skipped), so the kerberos-only properties stay in
# the XML and the daemons refuse to start with no KDC. That's
# expected — we exit before those checks.
# ---------------------------------------------------------------------
if [ "$MODE" = "disable-envtoxml" ]; then
    echo "=== disable-envtoxml verification (envtoxml skipped, heredoc rendered) ==="

    # Same 5s settle as the mount modes — entrypoint runs
    # synchronously, no daemons to wait for.
    sleep 5

    # (1) Container must still be RUNNING.
    if ! docker ps --format '{{.Names}}' | grep -qx "$SERVER"; then
        echo "FAIL: disable-envtoxml mode but container is not running"
        docker logs "$SERVER" 2>/dev/null || true
        exit 1
    fi
    echo "  container: still running"

    # (2) The entrypoint must have rendered the heredoc + applied
    # sed placeholder substitution. dfs.replication=1 (heredoc
    # default), not =999 from the env var.
    HDFS_XML_CONTENT=$(docker exec "$SERVER" cat /opt/hadoop/etc/hadoop/hdfs-site.xml 2>/dev/null || true)
    if [ -z "$HDFS_XML_CONTENT" ]; then
        echo "FAIL: could not read container's hdfs-site.xml"
        docker logs "$SERVER"
        exit 1
    fi
    if ! echo "$HDFS_XML_CONTENT" | grep -q '<name>dfs.replication</name><value>1</value>'; then
        echo "FAIL: heredoc render broken (dfs.replication should =1)"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  heredoc render ok: dfs.replication=1 (env var =999 did NOT override)"

    # (3) Env var HDFS-SITE.XML_dfs.replication=999 must NOT have
    # landed. (The heredoc has dfs.replication=1; we passed =999;
    # the rendered file should say =1, not =999.)
    if echo "$HDFS_XML_CONTENT" | grep -q '<value>999</value>'; then
        echo "FAIL: env var HDFS-SITE.XML_dfs.replication=999 landed in XML"
        echo "  HDFS_DISABLE_ENVTOXML=1 did NOT skip envtoxml"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  envtoxml skipped: dfs.replication env var did NOT land"

    # (4) New env var smoke.test.envvar=SHOULD_NOT_LAND must NOT
    # be present. envtoxml was skipped entirely, so no appends.
    if echo "$HDFS_XML_CONTENT" | grep -q 'smoke.test.envvar'; then
        echo "FAIL: envtoxml appended smoke.test.envvar to XML"
        echo "  HDFS_DISABLE_ENVTOXML=1 did NOT skip envtoxml"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  envtoxml skipped: smoke.test.envvar=SHOULD_NOT_LAND not in XML"

    # (5) Loud WARN about disable-envtoxml + simple-mode clash
    # must have been logged. The simple-mode auto-strip is
    # implemented INSIDE the envtoxml pass, so disabling envtoxml
    # in simple mode leaves the kerberos-only properties in the
    # XML. The entrypoint prints a loud WARN to stderr for this
    # combination; docker logs captures both streams.
    WARN=$(docker logs "$SERVER" 2>&1 | grep -F 'HDFS_DISABLE_ENVTOXML=1 + HADOOP_SECURITY_AUTHENTICATION=simple' || true)
    if [ -z "$WARN" ]; then
        echo "FAIL: expected WARN about HDFS_DISABLE_ENVTOXML+simple clash was NOT logged"
        echo "  the entrypoint should print a loud warning before exec /init"
        docker logs "$SERVER" 2>&1 | sed 's/^/    /'
        exit 1
    fi
    echo "  WARN logged: HDFS_DISABLE_ENVTOXML+simple clash (expected, see entrypoint:89-117)"

    # (6) Verify the kerberos-only properties DID stay in the XML
    # (because envtoxml was skipped, so the simple-mode auto-strip
    # didn't run). This is the expected consequence of the WARN
    # above; we confirm by checking at least one stayed.
    if ! echo "$HDFS_XML_CONTENT" | grep -q 'dfs.namenode.kerberos.principal'; then
        echo "FAIL: dfs.namenode.kerberos.principal missing from rendered XML"
        echo "  (envtoxml-skip branch should have left it in place)"
        echo "$HDFS_XML_CONTENT" | sed 's/^/    /'
        exit 1
    fi
    echo "  kerberos-only property preserved: dfs.namenode.kerberos.principal still in XML (expected)"

    # (7) Verify the entrypoint actually took the disable-envtoxml
    # branch — the entrypoint logs a specific message
    # "envtoxml disabled (HDFS_DISABLE_ENVTOXML=1)" for each XML
    # it skipped.
    SKIP_MSG=$(docker logs "$SERVER" 2>&1 | grep -F 'envtoxml disabled (HDFS_DISABLE_ENVTOXML=1)' || true)
    if [ -z "$SKIP_MSG" ]; then
        echo "FAIL: entrypoint did not log 'envtoxml disabled' message"
        echo "  (HDFS_DISABLE_ENVTOXML branch not taken?)"
        docker logs "$SERVER" 2>&1 | sed 's/^/    /'
        exit 1
    fi
    SKIP_COUNT=$(echo "$SKIP_MSG" | wc -l)
    if [ "$SKIP_COUNT" != "2" ]; then
        echo "FAIL: expected 2 'envtoxml disabled' log lines (hdfs-site + core-site), got $SKIP_COUNT"
        echo "$SKIP_MSG" | sed 's/^/    /'
        exit 1
    fi
    echo "  'envtoxml disabled' logged for both XMLs (hdfs-site + core-site)"

    echo "=== SMOKE TEST PASSED (mode=${MODE}) ==="
    exit 0
fi

# ---------------------------------------------------------------------
# empty HDFS_SERVICES mode short-circuits. The point is to prove the
# entrypoint accepts an explicitly-empty HDFS_SERVICES value without
# falling back to a default. `: ${VAR:=default}` substitutes on empty
# values too, so the entrypoint's `: ${HDFS_SERVICES:=…}` line had
# to be removed to support empty-profile deployments. The remaining
# `${VAR+set}` probe correctly distinguishes "unset" from "set to
# empty" so the default block only fires for genuinely unset values.
# ---------------------------------------------------------------------
if [ "$MODE" = "empty" ]; then
    echo "=== empty HDFS_SERVICES verification (no services started) ==="

    # No daemons to wait for — entrypoint runs synchronously and
    # exec's /init, which runs an empty s6 bundle forever.
    sleep 5

    # (1) Container must still be RUNNING. No services = no
    # crashes possible.
    if ! docker ps --format '{{.Names}}' | grep -qx "$SERVER"; then
        echo "FAIL: empty mode but container is not running"
        echo "  (entrypoint FATAL'd on empty HDFS_SERVICES?)"
        docker logs "$SERVER" 2>/dev/null || true
        exit 1
    fi
    echo "  container: still running (entrypoint accepted empty HDFS_SERVICES)"

    # (2) s6-rc bundle must NOT contain any of the 4 Hadoop
    # services. The user bundle was compiled with no contents.d/
    # files (the for-loop iterates 0 times over an empty
    # HDFS_SERVICES).
    BUNDLE=$(docker exec "$SERVER" /command/s6-rc -a list 2>/dev/null || true)
    if [ -z "$BUNDLE" ]; then
        echo "FAIL: 's6-rc -a list' returned no output"
        docker logs "$SERVER"
        exit 1
    fi
    for svc in namenode datanode krb5kdc kadmind; do
        if echo "$BUNDLE" | grep -qx "$svc"; then
            echo "FAIL: empty mode but '${svc}' IS in s6-rc bundle"
            echo "  bundle:"; echo "$BUNDLE" | sed 's/^/    /'
            exit 1
        fi
    done
    echo "  bundle: empty user bundle (none of namenode/datanode/krb5kdc/kadmind present)"

    # (3) No services bound any port. We check 88 (KDC), 464
    # (kadmind), 8020 (NN RPC), 9870 (NN HTTP), 9866 (DN data),
    # 9864 (DN HTTP). Use /proc/net/tcp[6] like the issue #11
    # check.
    PROC_TCP=$(docker exec "$SERVER" cat /proc/net/tcp 2>/dev/null || true)
    PROC_TCP6=$(docker exec "$SERVER" cat /proc/net/tcp6 2>/dev/null || true)
    if [ -z "$PROC_TCP" ] || [ -z "$PROC_TCP6" ]; then
        echo "FAIL: could not read /proc/net/tcp[6] inside container"
        exit 1
    fi
    FAIL_PORT=0
    for port in 88 464 8020 9870 9866 9864; do
        port_hex=$(printf '%04X' "$port")
        v4=$(echo "$PROC_TCP" | awk -v p=":$port_hex" \
            '$2 ~ p"$" && $4 == "0A" {print $2; exit}')
        v6=$(echo "$PROC_TCP6" | awk -v p=":$port_hex" \
            '$2 ~ p"$" && $4 == "0A" {print $2; exit}')
        if [ -n "$v4" ] || [ -n "$v6" ]; then
            echo "FAIL: port $port (0x$port_hex) has a LISTEN — should be unbound"
            echo "      v4=$v4 v6=$v6"
            FAIL_PORT=1
        fi
    done
    if [ "$FAIL_PORT" = "1" ]; then
        docker logs "$SERVER"
        exit 1
    fi
    echo "  ports: 88/464/8020/9870/9866/9864 all unbound (no longruns started)"

    # (4) The entrypoint logged the resolved layout. The log
    # line must show the literal empty value (HDFS_SERVICES=
    # with no value after) and NOT a substituted default like
    # `namenode,datanode,krb5kdc,kadmind`.
    #
    # Two checks:
    #   (a) The layout line was logged at all (sanity).
    #   (b) The value between `=` and ` (` is empty, NOT a
    #       substituted default. We grep for the exact empty
    #       form: `HDFS_SERVICES= (HADOOP` — literal space
    #       immediately after the `=`. A substituted default
    #       would put a name (e.g. `namenode`) right after the
    #       `=` and would NOT match this pattern.
    #
    # Both greps use BRE (no -E) so `(` is a literal paren,
    # avoiding the ERE grouping-escape trap.
    LOG=$(docker logs "$SERVER" 2>&1)
    LAYOUT_LINE=$(echo "$LOG" | grep 'HDFS_SERVICES=.*HADOOP_SECURITY_AUTHENTICATION' | head -1 || true)
    if [ -z "$LAYOUT_LINE" ]; then
        echo "FAIL: entrypoint log missing 'HDFS_SERVICES=…(HADOOP_SECURITY_…)' layout line"
        echo "$LOG" | grep -i HDFS_SERVICES | sed 's/^/    /' || true
        exit 1
    fi
    # Default-substitution test: empty value → `=` immediately
    # followed by space. Default value → `=` followed by a name.
    if ! echo "$LAYOUT_LINE" | grep -q 'HDFS_SERVICES= (HADOOP'; then
        echo "FAIL: entrypoint substituted a default for empty HDFS_SERVICES"
        echo "  expected: HDFS_SERVICES= (HADOOP_SECURITY_AUTHENTICATION=…)"
        echo "  got:      ${LAYOUT_LINE}"
        exit 1
    fi
    echo "  entrypoint log shows HDFS_SERVICES= (empty value, not substituted)"

    echo "=== SMOKE TEST PASSED (mode=${MODE}) ==="
    exit 0
fi

echo "=== Waiting for NameNode (dfsadmin -report) ==="
for i in $(seq 1 120); do
    if docker exec "$SERVER" gosu hdfs \
        /opt/hadoop/bin/hdfs dfsadmin -fs "hdfs://${HOST}:8020" -report \
        >/dev/null 2>&1; then
        echo "  NameNode ready after ${i}s"
        break
    fi
    sleep 2
done

if ! docker exec "$SERVER" gosu hdfs \
        /opt/hadoop/bin/hdfs dfsadmin -fs "hdfs://${HOST}:8020" -report \
        >/dev/null 2>&1; then
    echo "FAIL: NameNode did not become ready"
    docker logs "$SERVER"
    exit 1
fi

echo "=== Waiting for at least one live DataNode ==="
LIVE_DNS=""
for i in $(seq 1 120); do
    # Hadoop 3.x prints "Live datanodes (N):" not "Live: N". The
    # number inside the parens is what we care about.
    LIVE_DNS=$(docker exec "$SERVER" gosu hdfs \
        /opt/hadoop/bin/hdfs dfsadmin -fs "hdfs://${HOST}:8020" -report 2>/dev/null \
        | grep -E '^Live datanodes \([0-9]+\):' || true)
    COUNT=$(echo "$LIVE_DNS" | sed -E 's/.*\(([0-9]+)\).*/\1/')
    if [ -n "$COUNT" ] && [ "$COUNT" -ge 1 ]; then
        echo "  $LIVE_DNS (after $((i*2))s)"
        break
    fi
    sleep 2
done

if [ -z "$COUNT" ] || [ "$COUNT" -lt 1 ]; then
    echo "FAIL: no live DataNodes after 240s"
    echo "  final: $LIVE_DNS"
    docker logs "$SERVER"
    exit 1
fi

# ---------------------------------------------------------------------
# Issue #8 regression: the DataNode's registered ip_addr must NOT be
# 127.0.0.1. With dfs.namenode.rpc-address=0.0.0.0 (the old template
# default) the DN→NN registration RPC traversed loopback and the NN
# recorded ip_addr=127.0.0.1; cross-pod clients (CSI, opendal,
# hdfs-native) then fail to read blocks. The template now uses
# __HDFS_HOSTNAME__:port + rpc-bind-host=0.0.0.0, so the IP recorded
# should be the container's real interface IP. Simple mode passes the
# same value via env (HDFS-SITE.XML_dfs.namenode.rpc-address), which
# carries the same fix; this check catches a regression in either
# path.
#
# Hadoop 3.x reports each DN as "Name: <ip>:<port> (<hostname>)" on
# its own line; we read the live report and assert no Name/IP pair
# starts with 127.
# ---------------------------------------------------------------------
echo "=== Verifying DataNode ip_addr is not 127.0.0.1 (issue #8) ==="
REPORT=$(docker exec "$SERVER" gosu hdfs \
    /opt/hadoop/bin/hdfs dfsadmin -fs "hdfs://${HOST}:8020" -report 2>/dev/null || true)
LOOPBACK_DN=$(echo "$REPORT" \
    | grep -E '^Name: 127\.' || true)
if [ -n "$LOOPBACK_DN" ]; then
    echo "FAIL: DataNode registered with loopback ip_addr (issue #8 regression)"
    echo "$LOOPBACK_DN" | sed 's/^/  /'
    docker logs "$SERVER"
    exit 1
fi
# Surface the actual IP we got — useful diagnostic when this fails
# outside CI (no log retention).
FIRST_IP=$(echo "$REPORT" | grep -E '^Name: ' | head -1 | awk '{print $2}' || true)
echo "  DataNode Name: $FIRST_IP"

# ---------------------------------------------------------------------
# Issue #11 / #15 regression: NN + DN listeners must bind IPv4-capable
# sockets, not IPv6-only.
#
# Background (issues #11, #12, #15): on Debian 13 + OpenJDK 21 with
# `net.ipv6.bindv6only=0` (the Linux default), Java's
# `InetSocketAddress("0.0.0.0", port)` resolves IPv6-first and creates
# only an IPv6 listener — `[::]:port` in /proc/net/tcp6. IPv4-only
# clients (opendal, hdfs-native, anything that resolves A-only) then
# get ECONNREFUSED on the registered ip_addr. The hostname pattern
# (dfs.datanode.address=hostname:port) worked around this for DN
# data / http / https / ipc sockets (issues #11, #15 — ipc-address
# added when the DN IPC port was caught), but NN's rpc-bind-host
# stays at 0.0.0.0 to preserve the documented "ALL interfaces"
# semantic (single-container dev, port-published docker). So 8020 /
# 9870 still hit the dual-stack bind.
#
# The fix landed as a Dockerfile ENV (Dockerfile.debian / Dockerfile.ubuntu
# + their .mirror siblings): `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true`
# makes the JVM open AF_INET sockets only — every bind goes to
# /proc/net/tcp, none to /proc/net/tcp6. This single flag covers
# issues #11, #12, and #15 simultaneously (issue #12 is the
# DataNode info web server crashing on `[::1]:0` in k8s hostNetwork
# pods — same JVM dual-stack root cause).
#
# Detection:
#   1. JAVA_TOOL_OPTIONS env must contain `preferIPv4Stack=true` —
#      if the Dockerfile ENV didn't land, the rest of the check would
#      silently regress to issue #15 state.
#   2. /proc/net/tcp has a LISTEN on every hadoop port: 8020 (NN RPC),
#      9870 (NN HTTP), 9864 (DN HTTP), 9866 (DN data), 9867 (DN IPC).
#      9865 (DN HTTPS) is omitted: the heredoc's dfs.http.policy=
#      HTTP_ONLY means no HTTPS listener — adding HDFS-SITE.XML_
#      dfs.http.policy=HTTPS_ONLY would re-bind it, but that's an
#      operator override not the default smoke-test scope.
#
# /proc/net/tcp6 is read but only checked for the absence of LISTENs
# — with preferIPv4Stack=true the JVM should create zero IPv6 sockets,
# so any LISTEN in tcp6 indicates the stack preference did NOT take
# effect (operator override) but the test still passes as long as
# IPv4 LISTENs exist.
#
# We do NOT use nc -z against the container's own IPv4: on a
# dual-stack dev host the kernel routes IPv4 input to an IPv6
# wildcard listener, so nc -z would pass even when the regression is
# present. /proc/net/tcp is the authoritative source.
# ---------------------------------------------------------------------
echo "=== Verifying hadoop ports bind IPv4 (issues #11/#15) ==="
JAVA_TOOL_OPTIONS_ENV=$(docker exec "$SERVER" sh -c 'echo "${JAVA_TOOL_OPTIONS:-}"' 2>/dev/null || true)
if ! echo "$JAVA_TOOL_OPTIONS_ENV" | grep -q 'preferIPv4Stack=true'; then
    echo "FAIL: JAVA_TOOL_OPTIONS not set to preferIPv4Stack=true in container env"
    echo "  got: '${JAVA_TOOL_OPTIONS_ENV:-<unset>}'"
    echo "  Dockerfile ENV JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true did NOT land"
    docker logs "$SERVER"
    exit 1
fi
echo "  JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS_ENV}"

PROC_TCP=$(docker exec "$SERVER" cat /proc/net/tcp 2>/dev/null || true)
PROC_TCP6=$(docker exec "$SERVER" cat /proc/net/tcp6 2>/dev/null || true)
if [ -z "$PROC_TCP" ]; then
    echo "FAIL: could not read /proc/net/tcp inside container"
    exit 1
fi
FAIL=0
for port in 8020 9870 9864 9866 9867; do
    port_hex=$(printf '%04X' "$port")
    # IPv4 LISTEN (wildcard or specific): local_address ends with
    # :PORT and st=0A.  Format "00000000:PORT" or "XXXXXXXX:PORT".
    v4=$(echo "$PROC_TCP" | awk -v p=":$port_hex" \
        '$2 ~ p"$" && $4 == "0A" {print $2; exit}')
    if [ -z "$v4" ]; then
        # No IPv4 LISTEN on this port. Surface the IPv6 LISTEN
        # (if any) so the operator sees what happened.
        v6_wild=$(echo "$PROC_TCP6" | awk -v p=":$port_hex" \
            '$2 ~ p"$" && $4 == "0A" {print $2; exit}')
        echo "FAIL: port $port (0x$port_hex) has NO IPv4 LISTEN — issues #11/#15 regression"
        echo "      IPv6 wildcard LISTEN: ${v6_wild:-none}"
        FAIL=1
    else
        echo "  port $port (0x$port_hex) LISTEN: $v4 (ipv4)"
    fi
done
# Cross-check: /proc/net/tcp6 should have NO LISTENs with the JVM
# stack preference on. If the operator overrode JAVA_TOOL_OPTIONS to
# disable it (e.g. for IPv6-only clusters) we expect ipv6 LISTENs;
# warn but don't fail.
TCP6_LISTENS=$(echo "$PROC_TCP6" | awk '$4 == "0A"' || true)
if [ -n "$TCP6_LISTENS" ]; then
    echo "  /proc/net/tcp6 has LISTENs (operator may have disabled preferIPv4Stack)"
    echo "$TCP6_LISTENS" | awk '{printf "    %s\n", $2}'
fi
if [ "$FAIL" = "1" ]; then
    echo "  /proc/net/tcp (IPv4) dump:"
    echo "$PROC_TCP" | sed 's/^/    /'
    docker logs "$SERVER"
    exit 1
fi

# ---------------------------------------------------------------------
# envtoxml feature check. The kerberos and simple modes both pass
# env vars at `docker run` time, and the entrypoint's envtoxml pass
# must apply them to /opt/hadoop/etc/hadoop/*.xml. We assert each
# code path end-to-end here — the goal is "did envtoxml apply the
# change", not "is the XML schema-valid", so we use `grep` on the
# rendered file rather than parsing XML.
#
#   - kerberos mode: tests 3 paths with 3 dedicated smoke env vars
#     (append / overwrite / !remove) — the only env vars that
#     mutate the rendered XML in a way that doesn't break the
#     kerberos auth path.
#   - simple mode: tests 7 !remove sentinels + 1 overwrite on
#     hdfs-site.xml, plus 1 !remove + 1 overwrite on core-site.xml.
#     These ARE the documented "Simple auth recipe" env vars; the
#     test confirms each one landed. Together with the kerberos
#     case this gives 100% envtoxml code-path coverage from smoke.
# ---------------------------------------------------------------------
HDFS_XML=/opt/hadoop/etc/hadoop/hdfs-site.xml
CORE_XML=/opt/hadoop/etc/hadoop/core-site.xml
HDFS_XML_CONTENT=$(docker exec "$SERVER" cat "${HDFS_XML}" 2>/dev/null || true)
CORE_XML_CONTENT=$(docker exec "$SERVER" cat "${CORE_XML}" 2>/dev/null || true)
if [ -z "$HDFS_XML_CONTENT" ] || [ -z "$CORE_XML_CONTENT" ]; then
    echo "FAIL: could not read ${HDFS_XML} / ${CORE_XML} from container"
    docker logs "$SERVER"
    exit 1
fi

if [ "$MODE" = "kerberos" ]; then
    echo "=== Verifying envtoxml injection (kerberos: append + overwrite + !remove) ==="

    # (a) APPEND: dfs.client.use.datanode.hostname=true — was NOT in
    # the template; envtoxml must append a new <property> for it.
    APPEND_LINE=$(echo "$HDFS_XML_CONTENT" \
        | grep -o '<name>dfs.client.use.datanode.hostname</name><value>true</value>' || true)
    if [ -z "$APPEND_LINE" ]; then
        echo "FAIL: envtoxml did not append dfs.client.use.datanode.hostname=true"
        docker exec "$SERVER" cat "${HDFS_XML}" || true
        exit 1
    fi
    echo "  append  ok: dfs.client.use.datanode.hostname=true"

    # (b) OVERWRITE: dfs.replication=2 — template had =1; the entry
    # count for that key must be exactly 1 (no duplicate from a
    # broken merge) AND its value must be 2.
    REPL_COUNT=$(echo "$HDFS_XML_CONTENT" | grep -c 'dfs\.replication' || true)
    if [ "$REPL_COUNT" != "1" ]; then
        echo "FAIL: envtoxml left ${REPL_COUNT} dfs.replication entries (want 1)"
        exit 1
    fi
    REPL_LINE=$(echo "$HDFS_XML_CONTENT" \
        | grep -o '<name>dfs.replication</name><value>2</value>' || true)
    if [ -z "$REPL_LINE" ]; then
        echo "FAIL: envtoxml did not overwrite dfs.replication to 2"
        docker exec "$SERVER" grep 'dfs.replication' "${HDFS_XML}" || true
        exit 1
    fi
    echo "  overwrite ok: dfs.replication=1 → 2 (single entry, no dup)"

    # (c) REMOVE: dfs.namenode.secondary.http-address=!remove — was
    # in the template (=0.0.0.0:0); the property must be GONE.
    if echo "$HDFS_XML_CONTENT" | grep -q 'dfs.namenode.secondary.http-address'; then
        echo "FAIL: envtoxml did not delete dfs.namenode.secondary.http-address (!remove)"
        docker exec "$SERVER" grep 'secondary.http-address' "${HDFS_XML}" || true
        exit 1
    fi
    # </configuration> must still be present — a botched truncate
    # could leave the file tail-broken; quick structural sanity.
    if ! echo "$HDFS_XML_CONTENT" | grep -q '</configuration>'; then
        echo "FAIL: envtoxml left hdfs-site.xml without </configuration> close tag"
        docker exec "$SERVER" tail -5 "${HDFS_XML}" || true
        exit 1
    fi
    echo "  remove  ok: dfs.namenode.secondary.http-address gone, file still well-formed"
fi

if [ "$MODE" = "simple" ]; then
    # Verify the entrypoint's simple-mode auto-strip landed
    # correctly in the rendered XMLs (issues #13, #14). The
    # entrypoint injects 8 hdfs-site.xml + 2 core-site.xml
    # overrides into the envtoxml child process — see
    # rootfs/docker-entrypoint.sh. The assertions below
    # confirm those overrides were applied: 7 !remove + 1
    # overwrite on hdfs-site.xml, 1 !remove + 1 overwrite on
    # core-site.xml.
    echo "=== Verifying simple-mode auto-strip (entrypoint, no env vars) ==="

    # (a) 7 kerberos-only properties must be GONE from hdfs-site.xml.
    #     Each is a keytab path, an SPN, or a SASL transport
    #     setting that has no analogue in Simple auth and would
    #     cause Hadoop to fail to start if left in.
    SIMPLE_REMOVED_KEYS=(
        dfs.namenode.kerberos.principal
        dfs.namenode.keytab.file
        dfs.datanode.kerberos.principal
        dfs.datanode.keytab.file
        dfs.web.authentication.kerberos.principal
        dfs.web.authentication.kerberos.keytab
        dfs.data.transfer.protection
    )
    for k in "${SIMPLE_REMOVED_KEYS[@]}"; do
        if echo "$HDFS_XML_CONTENT" | grep -q "<name>${k}</name>"; then
            echo "FAIL: envtoxml did not !remove ${k} from hdfs-site.xml"
            docker exec "$SERVER" grep "${k}" "${HDFS_XML}" || true
            exit 1
        fi
    done
    echo "  !remove ok: 7 kerberos-only properties gone from hdfs-site.xml"

    # (b) 1 OVERWRITE on hdfs-site.xml: dfs.block.access.token.enable
    # template had =true; env var =false must take effect AND no
    # duplicate entry.
    BAC_COUNT=$(echo "$HDFS_XML_CONTENT" | grep -c 'dfs\.block\.access\.token\.enable' || true)
    if [ "$BAC_COUNT" != "1" ]; then
        echo "FAIL: envtoxml left ${BAC_COUNT} dfs.block.access.token.enable entries (want 1)"
        exit 1
    fi
    if ! echo "$HDFS_XML_CONTENT" \
        | grep -q '<name>dfs.block.access.token.enable</name><value>false</value>'; then
        echo "FAIL: envtoxml did not overwrite dfs.block.access.token.enable to false"
        docker exec "$SERVER" grep 'block.access.token.enable' "${HDFS_XML}" || true
        exit 1
    fi
    echo "  overwrite ok: dfs.block.access.token.enable=true → false (single entry)"

    # (c) 1 !remove + 1 overwrite on core-site.xml.
    if echo "$CORE_XML_CONTENT" | grep -q '<name>hadoop.rpc.protection</name>'; then
        echo "FAIL: envtoxml did not !remove hadoop.rpc.protection from core-site.xml"
        docker exec "$SERVER" grep 'rpc.protection' "${CORE_XML}" || true
        exit 1
    fi
    echo "  !remove ok: hadoop.rpc.protection gone from core-site.xml"

    AUTHZ_COUNT=$(echo "$CORE_XML_CONTENT" | grep -c 'hadoop\.security\.authorization' || true)
    if [ "$AUTHZ_COUNT" != "1" ]; then
        echo "FAIL: envtoxml left ${AUTHZ_COUNT} hadoop.security.authorization entries (want 1)"
        exit 1
    fi
    if ! echo "$CORE_XML_CONTENT" \
        | grep -q '<name>hadoop.security.authorization</name><value>false</value>'; then
        echo "FAIL: envtoxml did not overwrite hadoop.security.authorization to false"
        docker exec "$SERVER" grep 'security.authorization' "${CORE_XML}" || true
        exit 1
    fi
    echo "  overwrite ok: hadoop.security.authorization=true → false (single entry)"

    # Both XMLs must still be well-formed end-to-end.
    if ! echo "$HDFS_XML_CONTENT" | grep -q '</configuration>'; then
        echo "FAIL: hdfs-site.xml missing </configuration> close after envtoxml merges"
        exit 1
    fi
    if ! echo "$CORE_XML_CONTENT" | grep -q '</configuration>'; then
        echo "FAIL: core-site.xml missing </configuration> close after envtoxml merges"
        exit 1
    fi
    echo "  structural ok: both XMLs still well-formed"
fi

if [ "$MODE" = "kerberos" ]; then
    echo "=== kinit testuser ==="
    # The testuser's password defaults to "testpass" (override via
    # KRB5_TESTUSER_PASS in the env, or by passing -e
    # KRB5_TESTUSER_PASS=... to docker run). The default is weak
    # by design — the smoke test only needs to exercise the SASL
    # path, not validate password policy. We pass the password
    # through to the container's kinit via the SAME env var, so the
    # test and the entrypoint agree on the credential without the
    # smoke script needing to know the default.
    #
    # MIT kinit reads the password from stdin when stdin is not a tty,
    # so we just pipe. There's no `-password` flag in MIT (that's a
    # Heimdal-ism).
    KRB5_TESTUSER_PASS="${KRB5_TESTUSER_PASS:-testpass}"
    docker exec "$SERVER" bash -c "
        set -e
        printf '%s\n' \"\${KRB5_TESTUSER_PASS:-testpass}\" | kinit testuser@${REALM}
        klist
    "
fi

echo "=== Writing test file into the container ==="
TEST_TXT="hello from dyrnq/hdfs smoke test @ $(date -u +%FT%TZ) (mode=${MODE})"
echo "$TEST_TXT" | docker exec -i "$SERVER" tee /tmp/smoke.txt >/dev/null

# A fresh NameNode has no user dirs — we follow the same convention as
# mntrs/docker/hdfs (its hdfs-kerberos job uses /test, its bench uses
# /user/mntrs): the test creates its own scratch dir under /smoke
# rather than relying on the conventional /tmp that Hadoop's NameNode
# does not auto-create.
echo "=== hdfs dfs -mkdir -p /smoke ==="
docker exec "$SERVER" gosu hdfs /opt/hadoop/bin/hdfs \
    dfs -mkdir -p /smoke 2>&1 \
    | sed 's/^/  /'

echo "=== hdfs dfs -put /tmp/smoke.txt /smoke/ ==="
docker exec "$SERVER" gosu hdfs /opt/hadoop/bin/hdfs \
    dfs -put /tmp/smoke.txt /smoke/ 2>&1 \
    | sed 's/^/  /'

echo "=== hdfs dfs -cat /smoke/smoke.txt ==="
GOT=$(docker exec "$SERVER" gosu hdfs /opt/hadoop/bin/hdfs \
    dfs -cat /smoke/smoke.txt 2>/dev/null)
echo "  $GOT"
if [ "$GOT" != "$TEST_TXT" ]; then
    echo "FAIL: round-trip mismatch"
    echo "  expected: $TEST_TXT"
    echo "  got:      $GOT"
    exit 1
fi

echo "=== hdfs dfs -ls /smoke ==="
docker exec "$SERVER" gosu hdfs /opt/hadoop/bin/hdfs dfs -ls /smoke 2>&1 \
    | sed 's/^/  /'

echo "=== SMOKE TEST PASSED (mode=${MODE}) ==="
