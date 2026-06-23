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
#       The image is kerberos-only by design. To exercise the
#       hadoop.security.authentication=Simple code path we run the
#       same entrypoint but pass HADOOP_SECURITY_AUTHENTICATION=simple
#       — that tells docker-entrypoint.sh to skip KDC bootstrap +
#       keytab + keystore generation, strip the krb5kdc + kadmind
#       s6 services, and let the namenode + datanode longruns come
#       up unauthenticated. We still bind-mount a Simple-auth
#       core-site.xml + hdfs-site.xml over /opt/hadoop/etc/hadoop/
#       so the rendered XMLs actually carry Simple + HTTP_ONLY. The
#       s6 longruns come up with those configs and the hdfs commands
#       run as the hdfs user with no kinit. The test still exercises
#       dfsadmin -report and a put/cat round trip.
#
# Usage:
#   ./scripts/smoke-test.sh                          # kerberos (default)
#   ./scripts/smoke-test.sh kerberos
#   ./scripts/smoke-test.sh simple
#   MODE=simple ./scripts/smoke-test.sh
#   IMAGE=dyrnq/hdfs:latest-ubuntu ./scripts/smoke-test.sh
set -euo pipefail

# Args: <mode> [image]
# Env:  MODE= MODE= IMAGE=
# Positional mode wins over env; positional image falls back to env
# then to the debian default.
MODE="${1:-${MODE:-kerberos}}"
case "${MODE}" in
    kerberos|simple) ;;
    *) echo "FAIL: unknown mode '${MODE}' (want: kerberos|simple)"; exit 2 ;;
esac
shift || true
IMAGE="${1:-${IMAGE:-dyrnq/hdfs:latest-debian}}"
HOST="${HDFS_HOSTNAME:-hdfs.test}"
REALM="${KRB5_REALM:-TEST.LOCAL}"
NET="hdfs-smoke-net-$$"
SERVER="hdfs-smoke-$$"
KRB5_PASS=""

cleanup() {
    docker rm -f "$SERVER" 2>/dev/null || true
    docker network rm "$NET" 2>/dev/null || true
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
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    SIMPLE_CORE="${SCRIPT_DIR}/conf/simple/core-site.xml"
    SIMPLE_HDFS="${SCRIPT_DIR}/conf/simple/hdfs-site.xml"
    if [ ! -f "$SIMPLE_CORE" ] || [ ! -f "$SIMPLE_HDFS" ]; then
        echo "FAIL: missing ${SIMPLE_CORE} or ${SIMPLE_HDFS}"
        exit 1
    fi
    echo "=== Starting container (simple, mount-overridden configs) ==="
    docker run -d --name "$SERVER" \
        --network "$NET" \
        --hostname "$HOST" \
        -e HDFS_HOSTNAME="$HOST" \
        -e HADOOP_SECURITY_AUTHENTICATION=simple \
        -v "${SIMPLE_CORE}:/opt/hadoop/etc/hadoop/core-site.xml:ro" \
        -v "${SIMPLE_HDFS}:/opt/hadoop/etc/hadoop/hdfs-site.xml:ro" \
        "$IMAGE"
fi

if [ "$MODE" = "kerberos" ]; then
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
# should be the container's real interface IP. Simple mode mounts the
# XMLs :ro from scripts/conf/simple/, which carries the same fix; this
# check catches a regression in either path.
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
# envtoxml feature check (kerberos mode only — simple mode mounts
# the XMLs :ro, so envtoxml's [ -w ] guard skips them; the append /
# overwrite / !remove code paths need a writable XML). The three
# values passed at docker run time must all be reflected in
# /opt/hadoop/etc/hadoop/hdfs-site.xml after the entrypoint applies
# envtoxml — confirming each code path end-to-end.
#
# We use `grep -c <name>` rather than parsing XML because the goal is
# "did envtoxml apply the change", not "is the XML schema-valid".
# Format-agnostic, and the surrounding `<value>...</value>` substring
# check confirms the value landed in the right element.
# ---------------------------------------------------------------------
if [ "$MODE" = "kerberos" ]; then
    echo "=== Verifying envtoxml injection (append + overwrite + !remove) ==="
    HDFS_XML=/opt/hadoop/etc/hadoop/hdfs-site.xml
    XML_CONTENT=$(docker exec "$SERVER" cat "${HDFS_XML}" 2>/dev/null || true)
    if [ -z "$XML_CONTENT" ]; then
        echo "FAIL: could not read ${HDFS_XML} from container"
        docker logs "$SERVER"
        exit 1
    fi

    # (a) APPEND: dfs.client.use.datanode.hostname=true — was NOT in
    # the template; envtoxml must append a new <property> for it.
    APPEND_LINE=$(echo "$XML_CONTENT" \
        | grep -o '<name>dfs.client.use.datanode.hostname</name><value>true</value>' || true)
    if [ -z "$APPEND_LINE" ]; then
        echo "FAIL: envtoxml did not append dfs.client.use.datanode.hostname=true"
        echo "  grep: $APPEND_LINE"
        docker exec "$SERVER" cat "${HDFS_XML}" || true
        exit 1
    fi
    echo "  append  ok: dfs.client.use.datanode.hostname=true"

    # (b) OVERWRITE: dfs.replication=2 — template had =1; the entry
    # count for that key must be exactly 1 (no duplicate from a
    # broken merge) AND its value must be 2.
    REPL_COUNT=$(echo "$XML_CONTENT" | grep -c 'dfs\.replication' || true)
    if [ "$REPL_COUNT" != "1" ]; then
        echo "FAIL: envtoxml left ${REPL_COUNT} dfs.replication entries (want 1)"
        exit 1
    fi
    REPL_LINE=$(echo "$XML_CONTENT" \
        | grep -o '<name>dfs.replication</name><value>2</value>' || true)
    if [ -z "$REPL_LINE" ]; then
        echo "FAIL: envtoxml did not overwrite dfs.replication to 2"
        docker exec "$SERVER" grep 'dfs.replication' "${HDFS_XML}" || true
        exit 1
    fi
    echo "  overwrite ok: dfs.replication=1 → 2 (single entry, no dup)"

    # (c) REMOVE: dfs.namenode.secondary.http-address=!remove — was
    # in the template (=0.0.0.0:0); the property must be GONE.
    if echo "$XML_CONTENT" | grep -q 'dfs.namenode.secondary.http-address'; then
        echo "FAIL: envtoxml did not delete dfs.namenode.secondary.http-address (!remove)"
        docker exec "$SERVER" grep 'secondary.http-address' "${HDFS_XML}" || true
        exit 1
    fi
    # </configuration> must still be present — a botched truncate
    # could leave the file tail-broken; quick structural sanity.
    if ! echo "$XML_CONTENT" | grep -q '</configuration>'; then
        echo "FAIL: envtoxml left hdfs-site.xml without </configuration> close tag"
        docker exec "$SERVER" tail -5 "${HDFS_XML}" || true
        exit 1
    fi
    echo "  remove  ok: dfs.namenode.secondary.http-address gone, file still well-formed"
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
