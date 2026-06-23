# dyrnq/hdfs — Self-contained HDFS + Kerberos KDC image

Single-container HDFS with an embedded MIT Kerberos KDC. The image
runs `krb5kdc` + `kadmind` + `hdfs namenode` + `hdfs datanode` under
[s6-overlay](https://github.com/just-containers/s6-overlay), so a
single `docker run` is enough to bring up an HDFS cluster you can
authenticate against with `kinit`.

Two base images are published, mirroring the layout of
[`dyrnq/krb5-server`](https://hub.docker.com/r/dyrnq/krb5-server).

## Variants

| Tag                          | Base                       | Dockerfile         |
|------------------------------|----------------------------|--------------------|
| `dyrnq/hdfs:latest`          | `debian:trixie-slim`       | `Dockerfile.debian` |
| `dyrnq/hdfs:latest-debian`   | `debian:trixie-slim`       | `Dockerfile.debian` |
| `dyrnq/hdfs:latest-ubuntu`   | `ubuntu:26.04`             | `Dockerfile.ubuntu` |

> `:latest` and `:latest-debian` are the same image.

## Quick start

```bash
docker run -d --name hdfs \
    --hostname hdfs.test \
    -p 8020:8020 -p 9870:9870 -p 9871:9871 \
    -p 9864:9864 -p 9865:9865 -p 9866:9866 \
    -p 88:88 -p 464:464 -p 749:749 \
    dyrnq/hdfs:latest
```

> The container **must** be started with `--hostname` matching the
> `HDFS_HOSTNAME` build arg (default `hdfs.test`). The kerberos
> principal and self-signed TLS cert are both bound to that
> hostname; a mismatch causes SASL auth to fail with
> `Connection reset by peer`.

The KDC master/admin password is auto-generated on first boot and
written to a root-only file inside the KDC volume:

```bash
docker exec hdfs cat /var/lib/krb5kdc/.krb5_pass
```

The file is mode `0600 root:root` and lives at `/var/lib/krb5kdc/`
— **inside the same volume as the KDC database**. The principal DB
(`/var/lib/krb5kdc/principal`) is encrypted with this password, so
keeping them together is the only way `kdb5_util` / `kadmin.local`
keep working across `docker rm` + `docker run -v ...:/var/lib/
krb5kdc` recreate cycles. The password is intentionally **not**
echoed to `docker logs` to avoid leaking the master credential to
anyone with log-reader access.

If you started the container with `-e KRB5_PASS=…`, the file is
created with that value (the entrypoint still needs to know the
password to run `kdb5_util create` on first boot). On subsequent
recreates you can stop passing the env var — the entrypoint reads
the password back from the volume file.

If the volume is dropped (`docker compose down -v`) the password
file goes with it and the entrypoint auto-generates a fresh realm
on the next start. There is intentionally no "auto-detect
mismatch and force-rebuild" path: a half-surviving volume (DB
present, `.krb5_pass` missing) is treated as a backup-restore
problem, not something to silently nuke.

Or use docker compose:

```bash
make build up           # debian
make build-ubuntu up-ubuntu
```

## Environment variables

| Variable                     | Required | Default      | Description |
|------------------------------|----------|--------------|-------------|
| `HDFS_HOSTNAME`              | no       | `hdfs.test`  | Service principal hostname. Should match the container's `--hostname`. |
| `KRB5_REALM`                 | no       | `TEST.LOCAL` | Kerberos realm. |
| `KRB5_KDC`                   | no       | `localhost`  | KDC hostname. Set to the container's hostname (or another KDC's address) so kinit can reach the KDC. |
| `KRB5_DOMAIN`                | no       | `test`       | Used in `krb5.conf` `domain_realm` mapping. |
| `KRB5_PASS`                  | no       | auto-gen     | Master + admin principal password. Auto-generated on first boot and stored at `/var/lib/krb5kdc/.krb5_pass` (mode 0600 root:root) **inside the KDC volume**, so the password survives `docker rm` + `docker run -v ...:/var/lib/krb5kdc` recreate cycles and stays in sync with the encrypted KDC database. Retrieve with `docker exec hdfs cat /var/lib/krb5kdc/.krb5_pass`. Not echoed to `docker logs` to avoid credential leakage. On subsequent boots the entrypoint reads the file back if `KRB5_PASS` is not passed via env. |
| `KRB5_TESTUSER_PASS`         | no       | `testpass`   | Password for the `testuser@REALM` principal that the entrypoint creates. Intentionally weak by default — the principal exists for the smoke test, not for real use. Override before exposing this image outside a dev/test boundary. |
| `HDFS_NAMENODE_RPC_PORT`     | no       | `8020`       | NameNode RPC port. Drives `dfs.namenode.rpc-address` + `fs.defaultFS` (shared) and the `dfsadmin -report` wait poll. |
| `HDFS_NAMENODE_AUTO_FORMAT`  | no       | `true`       | If `true` (default), the NameNode formats on first boot when `/var/lib/hadoop/namenode/current` is missing. Set to `false` to disable silent auto-format (e.g. when mounting a pre-formatted volume that must not be touched). |
| `HDFS_NAMENODE_FORCE_FORMAT` | no       | `false`      | If `true`, the NameNode formats unconditionally on every boot, wiping any existing fsimage. Destructive. Takes priority over `AUTO_FORMAT`. |
| `HADOOP_SECURITY_AUTHENTICATION` | no   | `kerberos`  | `kerberos` (default, embedded KDC) or `simple`. In `simple` mode the entrypoint (a) strips the `krb5kdc` + `kadmind` s6 services and (b) skips KDC bootstrap, keytab generation, and the self-signed keystore. The sed substitution below also rewrites `hadoop.security.authentication` in `core-site.xml` from the `__HADOOP_SECURITY_AUTHENTICATION__` placeholder to `simple`, which is enough to flip the s6 run scripts (`hdfs-common.sh: hdfs_auth_mode` reads the XML as the source of truth — defensive against a typo'd or hand-edited XML). The sed substitution does NOT touch the rest of the XML: `core-site.xml` keeps `hadoop.security.authorization=true` and `hadoop.rpc.protection=authentication`, and `hdfs-site.xml` keeps the kerberos principal/keytab/block-token properties. Those are harmless without a KDC (the principals never resolve, `dfs.http.policy` defaults to HTTP_ONLY so the missing keystore is fine). To produce a clean Simple-auth cluster — no leftover `*kerberos.principal` / `*.keytab.file` / `dfs.data.transfer.protection` / `hadoop.rpc.protection`, and `dfs.block.access.token.enable=false` + `hadoop.security.authorization=false` — set `HADOOP_SECURITY_AUTHENTICATION=simple` AND the env recipe in the next section. |
| `HDFS_KDC_WAIT_TIMEOUT`      | no       | `30`         | Number of attempts (≈2× wall seconds) the namenode + datanode run scripts poll the KDC port 88 for, before giving up with a FATAL log line. |
| `HDFS_NAMENODE_WAIT_TIMEOUT` | no       | `60`         | Number of attempts (≈2× wall seconds) the datanode run script polls `dfsadmin -report` for, before giving up with a FATAL log line. |
| `KEYSTORE_PASS`              | no       | `changeit`   | HTTPS self-signed keystore password. Ignored in simple mode (no keystore generated). |

### Injecting arbitrary Hadoop XML config (`<NAME>.XML_<key>`)

For everything else, any env var named `<NAME>.XML_<hadoop-key>=<value>`
is merged into `<name>.xml` at container start (inspired by
[apache/ozone](https://github.com/apache/ozone)'s `envtoconf` convention,
reimplemented here as a static Rust binary — `tools/envtoxml/` — so the
image needs no python3). For example:

```bash
docker run -e HDFS-SITE.XML_dfs.client.use.datanode.hostname=true \
           -e CORE-SITE.XML_fs.trash.interval=60 \
           dyrnq/hdfs:latest
```

- `HDFS-SITE.XML_…` targets `hdfs-site.xml`, `CORE-SITE.XML_…` targets
  `core-site.xml`; the `<NAME>` prefix (case-insensitive) selects the
  file by its basename minus `.xml`. Any `*.xml` under
  `/opt/hadoop/etc/hadoop/` is a valid target.
- A key already in the XML has its `<value>` **overwritten in place** (the
  `<property>` is not duplicated); a new key is **appended** before
  `</configuration>`. Comments and whitespace are preserved byte-for-byte.
- To **delete** a template-defined property, set its value to the sentinel
  `!remove`: `-e HDFS-SITE.XML_dfs.namenode.kerberos.principal=!remove`
  drops that `<property>` entirely (no-op if the key is absent). The
  sentinel goes in the value, not the name — env names are restricted to
  `[-._a-zA-Z0-9]` (k8s ConfigMap keys reject `!`).
- Values are XML-escaped (`& < >` …); config keys must match
  `[A-Za-z0-9._-]` (others are skipped with a warning). Read-only
  (bind-mounted) XMLs are left untouched — mount your own XML and you are
  fully in charge.

The most common use is overriding `dfs.namenode.rpc-address` in k8s (see
the Notes below).

### Simple auth recipe (drop the kerberos template's KDC-specific properties)

`HADOOP_SECURITY_AUTHENTICATION=simple` flips the run scripts off
Kerberos, but the in-image `hdfs-site.xml` / `core-site.xml` are
written for kerberos-first and still carry keytab paths, SPNs, and
`hadoop.rpc.protection=authentication`. The cleanest deployment is
to `!remove` the kerberos-only properties and overwrite the two
auth-mode flags via envtoxml, in the same `docker run`:

```bash
docker run -d --name hdfs \
  -e HADOOP_SECURITY_AUTHENTICATION=simple \
  -e HDFS_HOSTNAME=hdfs.test \
  -e "HDFS-SITE.XML_dfs.namenode.kerberos.principal=!remove" \
  -e "HDFS-SITE.XML_dfs.namenode.keytab.file=!remove" \
  -e "HDFS-SITE.XML_dfs.datanode.kerberos.principal=!remove" \
  -e "HDFS-SITE.XML_dfs.datanode.keytab.file=!remove" \
  -e "HDFS-SITE.XML_dfs.web.authentication.kerberos.principal=!remove" \
  -e "HDFS-SITE.XML_dfs.web.authentication.kerberos.keytab=!remove" \
  -e "HDFS-SITE.XML_dfs.data.transfer.protection=!remove" \
  -e "HDFS-SITE.XML_dfs.block.access.token.enable=false" \
  -e "CORE-SITE.XML_hadoop.rpc.protection=!remove" \
  -e "CORE-SITE.XML_hadoop.security.authorization=false" \
  dyrnq/hdfs:latest
```

This is exactly what `scripts/smoke-test.sh` does in simple mode
(the smoke test doubles as the documented recipe). For k8s, paste
the env list into a `Deployment`'s `env:` array or a ConfigMap.

Note: `dfs.datanode.hostname` is left in place — it's cosmetic
(`DatanodeID.hostName` only) and matches `HDFS_HOSTNAME` after the
entrypoint's sed pass, so leaving it is harmless.


## Build args

| Arg                | Default  | Description |
|--------------------|----------|-------------|
| `DEBIAN_VERSION`   | `trixie` | Debian base tag. |
| `UBUNTU_VERSION`   | `26.04`  | Ubuntu base tag. |
| `HADOOP_VERSION`   | `3.5.0`    | Hadoop release to install. |
| `HDFS_HOSTNAME`    | `hdfs.test` | Default hostname baked into principals and TLS cert. Override via runtime `HDFS_HOSTNAME` env if needed, but they must agree. |
| `S6_OVERLAY_VERSION` | `3.2.0.2` | s6-overlay release. |

## Ports

| Port  | Service                                |
|-------|----------------------------------------|
| 88    | Kerberos authentication (TCP/UDP)      |
| 464   | Kerberos password change (kpasswd)     |
| 749   | Kerberos admin (kadmind)               |
| 8020  | NameNode RPC                           |
| 9870  | NameNode Web UI (HTTP; default `HTTP_ONLY`)|
| 9871  | NameNode HTTPS (only under `HTTPS_ONLY`/`HTTP_AND_HTTPS`)|
| 9864  | DataNode HTTP                          |
| 9865  | DataNode HTTPS (only under `HTTPS_ONLY`/`HTTP_AND_HTTPS`)|
| 9866  | DataNode IPC                           |

## Volumes

Mount these to persist state across container restarts:

| Path                       | Contents                       |
|----------------------------|--------------------------------|
| `/var/lib/krb5kdc`         | KDC database (master key, principals) |
| `/var/lib/hadoop/namenode` | NameNode fsimage + edits log   |
| `/var/lib/hadoop/datanode` | DataNode block storage         |

## Using the cluster

From inside the container:

```bash
docker exec -it hdfs bash
# Kinit as testuser (password: defaults to 'testpass', override via
# KRB5_TESTUSER_PASS at run time)
kinit testuser@TEST.LOCAL
# HDFS CLI as the testuser (hdfs superuser)
gosu hdfs hdfs dfs -ls /
echo "hello" | tee /tmp/foo.txt
gosu hdfs hdfs dfs -put /tmp/foo.txt /tmp/
gosu hdfs hdfs dfs -cat /tmp/foo.txt
```

From a remote client, point its `/etc/krb5.conf` at the container:

```ini
[libdefaults]
    default_realm = TEST.LOCAL
    udp_preference_limit = 1
[realms]
    TEST.LOCAL = {
        kdc = tcp/<container-ip>:88
        admin_server = tcp/<container-ip>:749
    }
```

Then:

```bash
kinit -kt hdfs.keytab hdfs/hdfs.test@TEST.LOCAL
hdfs dfs -ls hdfs://hdfs.test:8020/
```

## Web UI

`http://<host>:9870` — the default `dfs.http.policy=HTTP_ONLY` serves
the UI over plain HTTP. To use `https://<host>:9871`, switch the policy
to `HTTPS_ONLY` or `HTTP_AND_HTTPS` (the self-signed keystore is
generated on first boot for exactly this — see Notes).

## Development

Run the envtoxml Rust crate's format check + tests locally:

```bash
make test-envtoxml       # or: cd tools/envtoxml && cargo fmt --check && cargo test
```

The same checks run in CI as the `lint` job (see
`.github/workflows/docker.yml`), so this catches the regressions CI
would catch — fmt drift and broken tests — before pushing. The Docker
build still recompiles envtoxml from source in its builder stage; no
separate build step is needed for the binary to land in the image.

## Smoke test

After building, run the end-to-end smoke test. The smoke test
exercises both auth modes through the same entrypoint:

```bash
make smoke-all                      # kerberos + simple
make smoke-kerberos                 # kerberos only
make smoke-simple                   # simple only (mount-overrides)
./scripts/smoke-test.sh simple dyrnq/hdfs:latest-ubuntu
```

The script (kerberos mode):

1. Brings up a single container with `--hostname hdfs.test`.
2. Waits for KDC port 88 and for `dfsadmin -report` to succeed.
3. Reads `KRB5_PASS` from `/var/lib/krb5kdc/.krb5_pass` inside
   the container (the entrypoint writes it there on first boot,
   inside the KDC volume so the password stays in sync with the
   encrypted principal DB across recreate cycles — see the
   `KRB5_PASS` row above).
4. Verifies at least one live DataNode.
5. Runs `kinit testuser@TEST.LOCAL`.
6. Round-trips a file through `hdfs dfs -put` / `hdfs dfs -cat`.
7. Cleans up the container and network.

In `simple` mode, the script:

1. Launches the container with `-e HADOOP_SECURITY_AUTHENTICATION=
   simple` (the entrypoint detects this, strips the `krb5kdc` +
   `kadmind` s6 services, and skips KDC bootstrap + keytab +
   keystore generation). It still bind-mounts
   `scripts/conf/simple/{core,hdfs}-site.xml` over
   `/opt/hadoop/etc/hadoop/` so the rendered XMLs carry
   `Simple` + `HTTP_ONLY` and have no kerberos principal /
   keytab / block-token properties.
2. Waits for NameNode + DataNode (no KDC, no kinit).
3. Round-trips a file through `hdfs dfs -put` / `-cat`.

> The simple-mode XML mounts are **read-only** (`:ro`). The
> entrypoint's XML write-back is guarded by a `[ -w ]` test, so
> read-only overrides simply pass through — Hadoop reads the
> mounted XML directly and the entrypoint never tries to clobber
> it.

## Notes

- The same `hdfs.keytab` is used by both the NameNode and DataNode
  because the principal (`hdfs/<hostname>@<REALM>`) is the same —
  this is a single-container deployment, not a multi-host cluster.
  For a multi-host cluster, split keytabs per host and mount them
  via the volumes above.
- The web UI ships as `HTTP_ONLY` (plain HTTP on `:9870`). A
  self-signed keystore is generated on first boot so operators who
  switch `dfs.http.policy` to `HTTPS_ONLY`/`HTTP_AND_HTTPS` get a
  working TLS chain on `:9871` out of the box. Replace
  `/etc/hadoop/keystore.jks` (and the `HADOOP_HDFS_HOME` /
  `HDFS_KEYSTORE_PATH` / `HDFS_KEYSTORE_PASS` exports appended to
  `hadoop-env.sh`) for production use.
- The NameNode is protected against silent reformat on
  corrupted / unmounted / wrong-path volumes. After every
  successful format the run script touches
  `/var/lib/hadoop/namenode/.dyrnq-hdfs-formatted`. On subsequent
  boots, if the marker exists but `current/` is missing, the
  script refuses to auto-format and exits non-zero so s6 marks
  the service down. The volume must be remounted or repaired;
  deliberate wipes require `HDFS_NAMENODE_FORCE_FORMAT=true`.
- The KDC is local-only by design; for a production cluster, point
  `KRB5_KDC` at a dedicated `dyrnq/krb5-server` instance and
  consider removing the KDC services from this image.
- The `kinit` calls in the namenode + datanode run scripts are
  **strict**: they `nc -z` poll port 88 to wait for the KDC
  listener (s6 only tracks process liveness, not port-open, so
  there is a small window where the daemon is up but the port
  is still binding) and surface kinit errors directly. The
  previous `2>/dev/null || true` swallowed the real error
  (`Keytab file not found`, `Client not found in Kerberos
  database`, `Key version number mismatch`, …) and surfaced
  10 seconds later as an unsearchable `Connection reset` inside
  the SASL RPC handler. If the KDC does not become reachable
  within 30s, or kinit returns non-zero, the run script writes
  a FATAL block to the logs and exits so s6 marks the service
  down. The shared logic lives in
  `/etc/s6-overlay/scripts/hdfs-common.sh` for the curious.
- The `HADOOP_HDFS_HOME` / `HDFS_KEYSTORE_PATH` / `HDFS_KEYSTORE_PASS`
  exports appended to `hadoop-env.sh` by the entrypoint are
  written idempotently: any prior lines matching the variable
  names are stripped before the new ones are appended, so
  repeated restarts do not accumulate duplicates on the
  persistent `/opt/hadoop` volume.
- Each Hadoop daemon writes its own rolling log file under
  `/opt/hadoop/logs/`:
  `hadoop-hdfs-namenode-<host>.log` and
  `hadoop-hdfs-datanode-<host>.log`. The daemons run in the
  FOREGROUND under s6 (so s6 can supervise them), which means
  Hadoop's own `--daemon` code path — the one that would normally
  pick the per-daemon log filename and switch to the RFA
  (rolling-file) appender — never fires. The namenode + datanode
  run scripts therefore set `HADOOP_LOGFILE` (per-daemon name) and
  `HADOOP_ROOT_LOGGER=INFO,console,RFA` by hand so each daemon
  lands a file AND still streams to stdout (`→ docker logs`).
  These two are scoped to the run scripts (not `hadoop-env.sh`)
  so short-lived client calls like the `dfsadmin -report` polls
  keep the `INFO,console` default and don't litter
  `/opt/hadoop/logs/hadoop.log`. The KDC daemons log separately to
  `/var/log/krb5/` via `kdc.conf` `[logging]`. So every daemon has
  an on-disk, rotated log file; `docker logs` remains the live
  aggregate stream. Note `/opt/hadoop/logs` lives in the image's
  writable layer (it is NOT one of the volumes above), so these
  files are ephemeral across `docker rm` + recreate — `docker logs`
  is the cross-restart record. Mount `/opt/hadoop/logs` yourself if
  you need the Hadoop files to survive. (GitHub issue #9.)
- `krb5.conf`, `core-site.xml`, and `hdfs-site.xml` ship inside
  the `rootfs/` tree (`rootfs/etc/krb5.conf` and
  `rootfs/opt/hadoop/etc/hadoop/`) and are copied by the single
  `COPY rootfs /` step at the bottom of each Dockerfile. The
  XMLs use literal `__PLACEHOLDER__` tokens (`__HDFS_HOSTNAME__`,
  `__KRB5_REALM__`, `__HADOOP_SECURITY_AUTHENTICATION__`, …) and
  the entrypoint is the sole substitution point. Hand-editing
  the XMLs in the repo root does nothing — edit the copies under
  `rootfs/` instead.
- The entrypoint's XML write-back (`cp -f` to the in-image path)
  is guarded by `[ -w ${HADOOP_ETC}/${f} ]`. If the XML is
  bind-mounted read-only (the smoke test's simple mode does
  this to inject `Simple` + `HTTP_ONLY` configs) the entrypoint
  skips the write-back silently and Hadoop reads the mounted
  XML directly. Operators who mount-override their own XMLs get
  the same behavior for free.
- **DataNode `ip_addr` / `dfs.namenode.rpc-address`** (GitHub issue #8):
  the NameNode records a DataNode's `ip_addr` as the **source IP of the
  DataNode→NameNode registration RPC** (Hadoop
  `DatanodeManager.registerDatanode` overwrites it — see the source refs
  in the `hdfs-site.xml` comment). With `dfs.namenode.rpc-address=0.0.0.0`
  the DataNode connects over loopback, so `ip_addr` is recorded as
  `127.0.0.1`, which breaks cross-pod clients (CSI nodeplugins,
  `opendal`/`hdfs-native`) that connect to DataNodes by `ip_addr`. The
  image therefore ships `dfs.namenode.rpc-address=__HDFS_HOSTNAME__:port`
  plus `dfs.namenode.rpc-bind-host=0.0.0.0`: the advertised address drives
  the registered `ip_addr` (= `resolve(HDFS_HOSTNAME)`), while the bind
  host keeps the NameNode listening on all interfaces. **k8s caveat**:
  `HDFS_HOSTNAME` (and the container `--hostname`) must resolve to the pod
  IP — a short name mapped to `127.0.0.1` in `/etc/hosts` (a common k8s
  pod default) defeats this, so use the pod's headless-Service FQDN or set
  `HDFS_HOSTNAME` to the pod IP. (Note: `dfs.datanode.hostname` only sets
  the `host_name` field, not `ip_addr`; `dfs.datanode.dns.interface` does
  neither — both were investigated and ruled out in issue #8.) Override
  at runtime without a rebuild with
  `-e HDFS-SITE.XML_dfs.namenode.rpc-address=<pod-ip>:<port>`.
- **DataNode IPv6-only bind regression** (GitHub issue #11): on
  IPv6-first JVMs (Debian 13 + OpenJDK 21), `InetSocketAddress("0.0.0.0", …)`
  resolves IPv6 first, so a DataNode configured with the old
  `dfs.datanode.address=0.0.0.0:9866` ended up listening on `[::]:9866`
  only — every IPv4 client (opendal, hdfs-native, anything that
  resolves the DN hostname via A-only) got `ECONNREFUSED` on the
  registered IPv4 `ip_addr`. The image now ships
  `dfs.datanode.address=__HDFS_HOSTNAME__:port` (and the matching
  `http-address` / `https-address`), which makes the DN bind a
  **non-IPv6-wildcard** address — in practice an IPv4-mapped IPv6
  socket on `::ffff:<resolved-ip>:port` in `/proc/net/tcp6`
  (FFFF0000 prefix). The kernel still routes IPv4 input to that
  socket on a dual-stack system, so IPv4 clients can connect; the
  regression-test (smoke) verifies the bind is not the pure
  `[::]:port` form. Note: this image does **not** ship
  `dfs.datanode.bind-host=0.0.0.0` — `DFS_DATANODE_BIND_HOST_KEY`
  does not exist in Hadoop 3.5.0 (only NN / Balancer / JournalNode
  / Provided-aliasmap have bind-host keys; DN does not), so the
  `hostname:port` pattern alone is what protects streaming + IPC +
  HTTPS sockets. **k8s caveat** is the same as issue #8:
  `HDFS_HOSTNAME` must resolve to the pod IP. Override at runtime
  with
  `-e HDFS-SITE.XML_dfs.datanode.address=<pod-ip>:<port> \
   -e HDFS-SITE.XML_dfs.datanode.http.address=<pod-ip>:9864 \
   -e HDFS-SITE.XML_dfs.datanode.https.address=<pod-ip>:9865`.
- **DataNode info-web server bind crash on IPv6-only pods** (GitHub
  issue #12, upstream bug): the DataNode opens an additional
  listener for the info web UI, separate from the data / IPC / HTTPS
  sockets. The Jetty builder in
  `org.apache.hadoop.hdfs.server.datanode.web.DatanodeHttpServer`
  hard-codes
  `addEndpoint(URI.create("http://localhost:" + proxyPort))` and
  `setFindPort(true)`, so `proxyPort` is ephemeral and the bind
  address is the literal string `"localhost"` — no config, env var,
  or system property reaches it. On Debian 13 + OpenJDK 21 + k8s
  `hostNetwork: true` pods whose netns has no `[::1]` route,
  `InetAddress.getByName("localhost")` returns `[::1]` first
  (`net.ipv6.bindv6only=0`), Jetty tries `bind([::1]:0)`, and the
  kernel returns `EADDRNOTAVAIL`. The DataNode then shuts down
  (`BindException: Failed to bind to /[0:0:0:0:0:0:0:1]:0`). The
  image does **not** default `preferIPv4Stack=true` — opt in per
  container when you hit the crash:
  ```bash
  -e JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true
  ```
  This forces `getByName("localhost")` to return `127.0.0.1` (always
  routable in the pod's netns), so the info-web server binds
  `127.0.0.1:<ephemeral>` and proceeds. The flag is JVM-wide, so
  other daemons in the container (NN / KDC) also resolve hostnames
  IPv4-first; they don't bind `localhost`, so it has no observable
  effect on them. Once upstream fixes
  `DatanodeHttpServer.java:122` (replacing `"localhost"` with
  `DFS_DATANODE_BIND_HOST_KEY`-derived value), this opt-in can be
  removed.

