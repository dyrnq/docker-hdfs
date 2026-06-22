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
: "${HDFS_NAMENODE_HTTPS_PORT:=9871}"
: "${KEYSTORE_PASS:=changeit}"
# Auth mode: "kerberos" (default, image runs the embedded KDC) or
# "simple" (HADOOP_SECURITY_AUTHENTICATION=Simple). In simple mode we
# (a) strip the s6 service definitions for krb5kdc + kadmind so they
# never start and (b) skip the KDC bootstrap + principal/keytab +
# keystore block below — see the case statement guarding that block
# for the rationale.
#
# What the sed substitution below does and does NOT do for simple
# mode: it DOES flip the `hadoop.security.authentication` property in
# core-site.xml from the `__HADOOP_SECURITY_AUTHENTICATION__`
# placeholder to `simple`. It does NOT touch the rest of the XML —
# core-site.xml keeps `hadoop.security.authorization=true` and
# `hadoop.rpc.protection=authentication`, and hdfs-site.xml keeps
# the kerberos principal/keytab/block-token properties. Those
# properties are harmless without a KDC (the principals never
# resolve) but `dfs.http.policy` defaults to HTTP_ONLY at the image
# level, so a missing keystore is fine. Operators who want a true
# Simple-auth cluster (no kerberos properties at all, possibly
# `dfs.http.policy=HTTPS_ONLY` later) must mount-override both XMLs
# — `scripts/conf/simple/{core,hdfs}-site.xml` in the smoke test
# is the reference pair.
#
# Env propagation to the s6 longruns is reliable in simple mode too
# because simple mode no longer bypasses the entrypoint — see
# `hdfs-common.sh: hdfs_auth_mode` for the XML-vs-env discussion of
# which signal the run scripts prefer.
: "${HADOOP_SECURITY_AUTHENTICATION:=kerberos}"

HADOOP_ETC=/opt/hadoop/etc/hadoop
KEYTAB=/etc/hadoop/hdfs.keytab
KEYSTORE=/etc/hadoop/keystore.jks

# Strip KDC longruns from the s6-rc service tree when running in
# simple auth mode. The contents.d files are how s6-rc enumerates
# which services to bring up — removing a service from there is the
# supported way to disable it. We do this before the KDC bootstrap
# block below, so the deleted service files are gone by the time
# /init starts s6 later in this entrypoint.
#
# In kerberos mode (the default), namenode/dependencies.d/krb5kdc
# forces namenode to wait for the KDC longrun to come up before it
# starts — required because the namenode run script does
# `kinit -kt ... hdfs/...@REALM`, which authenticates against the
# KDC. In simple mode there is no KDC, so the dep edge is dangling
# and must also be removed.
#
# kadmind/dependencies.d/krb5kdc becomes an orphan file under
# /etc/s6-overlay/s6-rc.d/ but is harmless: s6-rc only considers
# services listed under user/contents.d/.
case "${HADOOP_SECURITY_AUTHENTICATION}" in
    [Ss]imple)
        echo "=== HADOOP_SECURITY_AUTHENTICATION=${HADOOP_SECURITY_AUTHENTICATION}: removing krb5kdc + kadmind s6 services ==="
        rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/krb5kdc \
              /etc/s6-overlay/s6-rc.d/user/contents.d/kadmind \
              /etc/s6-overlay/s6-rc.d/namenode/dependencies.d/krb5kdc
        ;;
esac

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

for f in hdfs-site.xml core-site.xml; do
    sed \
        -e "s|__HDFS_HOSTNAME__|${HDFS_HOSTNAME}|g" \
        -e "s|__KRB5_REALM__|${KRB5_REALM}|g" \
        -e "s|__HDFS_NAMENODE_RPC_PORT__|${HDFS_NAMENODE_RPC_PORT}|g" \
        -e "s|__HDFS_NAMENODE_HTTPS_PORT__|${HDFS_NAMENODE_HTTPS_PORT}|g" \
        -e "s|__HADOOP_SECURITY_AUTHENTICATION__|${HADOOP_SECURITY_AUTHENTICATION}|g" \
        "${HADOOP_ETC}/${f}" > "${TMPDIR_ENT}/${f}"
done

# Write the rendered XMLs back to the in-image paths so Hadoop reads
# the placeholder-substituted versions on container start. The
# Dockerfile does NOT do any build-time substitution — the XMLs
# ship with literal `__HDFS_HOSTNAME__` placeholders and this
# entrypoint is the sole substitution point. The cp-back is skipped
# if the destination is not writable: that happens when the XML is
# mount-overridden read-only (the smoke test's simple mode does
# this to inject Simple-auth XMLs) or when the source is already
# concrete (no placeholders to substitute, override survives as-is
# either way).
for f in hdfs-site.xml core-site.xml; do
    if [ ! -w "${HADOOP_ETC}/${f}" ]; then
        echo "=== ${HADOOP_ETC}/${f} is not writable (mount override?); using source as-is ==="
        continue
    fi
    cp -f "${TMPDIR_ENT}/${f}" "${HADOOP_ETC}/${f}"
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
    printf 'export HDFS_KEYSTORE_PATH=%s\n' "${KEYSTORE}"
    printf 'export HDFS_KEYSTORE_PASS=%s\n' "${KEYSTORE_PASS}"
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
