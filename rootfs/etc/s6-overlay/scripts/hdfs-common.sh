# Shared helpers for the hdfs s6 longrun scripts (namenode, datanode).
#
# Sourced — not executed — by each run script. The file is shipped
# in the image via `COPY rootfs /` in the Dockerfile. Sourced files
# do not need the execute bit; 0644 (the default from COPY) is
# sufficient.

# ---------------------------------------------------------------------------
# Configurable timeouts (env override).
#
# The numbers below are ATTEMPT COUNTS, not wall-clock seconds.
# Both hdfs_wait_for_kdc and hdfs_wait_for_namenode run one
# attempt + 2s sleep, so the max wall clock is roughly
# 2 × timeout. Defaults 30/60 therefore yield ~60s/~120s wall.
# Keeping both env vars in the same unit (attempts) lets users
# set both ceilings with consistent semantics.
# ---------------------------------------------------------------------------
: "${HDFS_KDC_WAIT_TIMEOUT:=30}"
: "${HDFS_NAMENODE_WAIT_TIMEOUT:=60}"

# hdfs_auth_mode
#
#   Echo "simple" or "kerberos" based on the live core-site.xml
#   (the actual config Hadoop will use). We read the XML rather
#   than checking the HADOOP_SECURITY_AUTHENTICATION env var
#   because:
#
#   1. Defensive coding against typo'd XMLs: a user can hand-edit
#      or mount-override core-site.xml with the Simple property but
#      leave the env unset (or vice versa). The XML is what
#      Hadoop actually parses; the env is just a hint to the
#      entrypoint. We err on the side of "do what the XML says" so
#      the daemon's auth mode and the run-script's kinit behavior
#      can't disagree.
#
#   2. Uniformity across both modes: since the 2026-06 refactor
#      the smoke test's simple mode ALSO goes through docker-
#      entrypoint.sh (via -e HADOOP_SECURITY_AUTHENTICATION=
#      simple), so the env is now a reliable signal in both modes
#      — but the XML check is still the safest source of truth
#      because it survives even an entrypoint-bypass run (the
#      pure-init run path some operators use when wiring the image
#      into kubernetes sidecars).
#
#   Default: "kerberos". The image's in-tree core-site.xml always
#   sets the property; "missing" means a hand-edited or replaced
#   XML. We err on the side of attempting kinit so a typo in a
#   mount-override does not silently bypass authentication.
#
#   The regex is anchored on BOTH ends (`<name>...</name>` AND
#   `</value>`) — earlier versions anchored only on `<name>`, so a
#   value like `<value>SimpleSasl</value>` or `<value>Simpler</value>`
#   would false-positive as "simple". Trailing `</value>` is
#   required by Hadoop's serializer, so the anchor is reliable.
hdfs_auth_mode() {
    local core="${HADOOP_HOME}/etc/hadoop/core-site.xml"
    if [ ! -f "${core}" ]; then
        echo "kerberos"
        return
    fi
    if grep -Eq '<name>[[:space:]]*hadoop\.security\.authentication[[:space:]]*</name>[[:space:]]*<value>[[:space:]]*[Ss]imple[[:space:]]*</value>' \
            "${core}" 2>/dev/null; then
        echo "simple"
    else
        echo "kerberos"
    fi
}

# hdfs_wait_for_kdc [timeout_attempts]
#
#   Poll the KDC's TCP port (88) until it accepts connections,
#   with a timeout. s6 only tracks the krb5kdc longrun's process
#   liveness, not whether the daemon has bound port 88 — there is
#   a brief window between the process appearing in s6's eyes
#   (which fires the dependency edge) and the listener actually
#   accepting connections. kinit against an unready KDC fails
#   with "Cannot contact any KDC"; the old `2>/dev/null || true`
#   swallowed that into a downstream "Connection reset" inside the
#   namenode RPC handler 10s later. This helper closes the race.
#
#   timeout_attempts defaults to ${HDFS_KDC_WAIT_TIMEOUT} (30 if
#   unset). Each attempt: 1s nc -w + 1s sleep = 2s wall, so the
#   max wall clock is roughly 2 × timeout. Returns 0 on success,
#   1 on timeout. Progress logged every 10 attempts so 30s waits
#   don't look dead in `docker logs`.
hdfs_wait_for_kdc() {
    local timeout="${1:-${HDFS_KDC_WAIT_TIMEOUT}}"
    local kdc="${KRB5_KDC:-localhost}"
    local port=88
    echo "[hdfs] Waiting for KDC at ${kdc}:${port} (timeout ${timeout} attempts ≈ $((timeout*2))s wall)..."
    local _i
    for _i in $(seq 1 "${timeout}"); do
        if nc -z -w 1 "${kdc}" "${port}" 2>/dev/null; then
            return 0
        fi
        if [ $((_i % 10)) -eq 0 ]; then
            echo "[hdfs]   still waiting for KDC (${_i}/${timeout})..."
        fi
        sleep 1
    done
    echo "[hdfs] FATAL: KDC at ${kdc}:${port} did not become reachable within ${timeout} attempts" >&2
    echo "[hdfs] Check that the krb5kdc s6 service is up and the KDC database is initialized." >&2
    return 1
}

# hdfs_kinit <principal>
#
#   kinit for the named principal using /etc/hadoop/hdfs.keytab.
#   The old `2>/dev/null || true` pattern hid the actual kinit
#   error from `docker logs`: the same conditions surfaced 10s
#   later as an unsearchable "Connection reset" inside the
#   namenode RPC handler. With the error left visible, operators
#   see the real kinit error in the logs — "Keytab file not
#   found", "Client not found in Kerberos database", "Key version
#   number mismatch" — and can fix the root cause directly.
#
#   Pre-flight diagnostics: dumps klist -kt for the keytab so the
#   operator can see entries and kvno values before kinit fails.
#   Pre-flight kdestroy clears any stale ccache that might shadow
#   the keytab (`-t` should override but MIT behavior varies).
#
#   Returns 0 on success, 1 on failure. On failure a FATAL block
#   is written to stderr describing the most common causes.
hdfs_kinit() {
    local principal="$1"
    local keytab=/etc/hadoop/hdfs.keytab

    # Keytab readable by hdfs user? `gosu hdfs test -r` would also
    # work but adds a process fork; check as root via the
    # current uid and then trust gosu for the kinit itself.
    if [ ! -r "${keytab}" ]; then
        echo "[hdfs] FATAL: keytab ${keytab} missing or not readable by uid $(id -u)" >&2
        echo "[hdfs] If you mount-override /etc/hadoop, the keytab must be inside the mount." >&2
        return 1
    fi

    echo "[hdfs] keytab entries (klist -kt ${keytab}):"
    gosu hdfs klist -kt "${keytab}" 2>&1 | sed 's/^/[hdfs]   /' || echo "[hdfs]   (klist failed; will still try kinit)"

    # Stale ccache from a previous container run can confuse
    # subsequent kinit. `-A` clears all collections; `|| true`
    # because kdestroy exits non-zero if there's no current ccache.
    gosu hdfs kdestroy -A 2>/dev/null || true

    if ! gosu hdfs /usr/bin/kinit -kt "${keytab}" "${principal}"; then
        echo "[hdfs] FATAL: kinit failed for ${principal}" >&2
        echo "[hdfs] Common causes: keytab missing, keytab expired, or kvno mismatch with the KDC." >&2
        echo "[hdfs] To rotate the keytab, restart with a fresh /var/lib/krb5kdc volume." >&2
        return 1
    fi
}

# hdfs_setup_kerberos_auth <component_name>
#
#   One-shot helper that runs the standard kerberos bootstrap
#   used by both namenode and datanode longruns. Reads the
#   auth mode from core-site.xml (the source of truth — see
#   `hdfs_auth_mode` for the XML-vs-env discussion). In simple
#   mode, prints a skip line and returns 0. In kerberos mode,
#   waits for KDC then kinit. On any failure returns non-zero
#   so `set -e` kills the longrun (s6 then restarts it per its
#   policy).
hdfs_setup_kerberos_auth() {
    local component="${1:-hdfs}"
    if [ "$(hdfs_auth_mode)" = "simple" ]; then
        echo "[${component}] hadoop.security.authentication=Simple: skipping kinit"
        return 0
    fi
    hdfs_wait_for_kdc || return 1
    hdfs_kinit "hdfs/${HDFS_HOSTNAME:-localhost}@${KRB5_REALM:-TEST.LOCAL}" || return 1
}

# hdfs_wait_for_namenode [timeout_attempts]
#
#   Poll the NameNode's dfsadmin -report endpoint until it
#   answers. We probe the report (not just the port) because the
#   RPC port opens before the RPC handler is ready; an actual
#   dfsadmin round-trip is the meaningful "NN is up" signal.
#
#   timeout_attempts defaults to ${HDFS_NAMENODE_WAIT_TIMEOUT}
#   (60 if unset). Each attempt is one dfsadmin + 2s sleep, so
#   total wall clock ≈ 2 × timeout. Progress logged every 5
#   attempts. Returns 0 on success, 1 on timeout.
#
#   NOTE: the env var's unit is attempts (not wall-clock seconds)
#   — same as HDFS_KDC_WAIT_TIMEOUT, so a user setting both
#   `HDFS_KDC_WAIT_TIMEOUT=30` and `HDFS_NAMENODE_WAIT_TIMEOUT=60`
#   gets a consistent "30 KDC attempts ≈ 60 NN attempts" ceiling.
hdfs_wait_for_namenode() {
    local timeout="${1:-${HDFS_NAMENODE_WAIT_TIMEOUT}}"
    local host="${HDFS_NAMENODE_HOST:-${HDFS_HOSTNAME:-localhost}}"
    local port="${HDFS_NAMENODE_RPC_PORT:-8020}"
    echo "[hdfs] Waiting for NameNode at ${host}:${port} (timeout ${timeout} attempts ≈ $((timeout*2))s wall)..."
    local _i
    for _i in $(seq 1 "${timeout}"); do
        if gosu hdfs /opt/hadoop/bin/hdfs dfsadmin \
                -fs "hdfs://${host}:${port}" -report >/dev/null 2>&1; then
            echo "[hdfs] NameNode ready"
            return 0
        fi
        if [ $((_i % 5)) -eq 0 ]; then
            echo "[hdfs]   still waiting for NameNode (${_i}/${timeout})..."
        fi
        sleep 2
    done
    echo "[hdfs] FATAL: NameNode at ${host}:${port} did not become ready within ${timeout} attempts (≈$((timeout*2))s wall)" >&2
    echo "[hdfs] Check the namenode s6 service logs for startup errors." >&2
    return 1
}