tor-rotating-proxy
==================

[![Docker Pulls](https://img.shields.io/docker/pulls/shaddysignal/tor-rotating-proxy.svg)](https://hub.docker.com/r/shaddysignal/tor-rotating-proxy/)

```
               Docker container (one unprivileged user, read-only root)
               ---------------------------------------------------------
                                           <-> Tor client 0  (sandboxed)
Client <--->  HAProxy (SOCKS5 :9050)       <-> Tor client 1  (sandboxed)
              stats page (:4444, opt-in)   <-> Tor client n  (sandboxed)
                                 supervisor: rotates circuits, replaces
                                 broken instances, restarts crashed ones
```

**Why:** many exit IP addresses behind one SOCKS5 endpoint. HAProxy balances
connections across a pool of independent Tor clients; a small supervisor asks
every client for fresh circuits on a schedule and replaces any client whose
circuits stop working.

The image assumes a hostile environment: its logs, its ports and even its
filesystem may be visible to someone who should learn as little as possible
from them. See [Hardening](#hardening) for what that means in practice.

Quick start
-----------

```bash
docker run -d --name tor-proxy --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /var/lib/tor:mode=0700,uid=10001,gid=10001,size=512m \
  --tmpfs /run/tor-proxy:mode=0700,uid=10001,gid=10001,size=8m \
  --log-opt max-size=10m --log-opt max-file=3 \
  -p 127.0.0.1:9050:9050 \
  -e TORS=8 \
  shaddysignal/tor-rotating-proxy:latest

# use it
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip

# watch it
docker logs -f tor-proxy
```

The stats page is off unless you give it credentials. To enable it, add
`-p 127.0.0.1:4444:4444 -e STATS_AUTH=admin:a-long-passphrase` (or better,
`STATS_AUTH_FILE`, see below) and open `http://127.0.0.1:4444/haproxy?stats`.

Or with Compose, which applies the same hardening and works without any
edits (see [compose.yaml](compose.yaml)):

```bash
docker compose up -d                       # builds from this checkout, SOCKS5 on 127.0.0.1:9050
cp .env.example .env                       # optional: instance count, ports, stats page, limits
```

To enable the stats page under Compose, put `user:password` on one line in a
file and point `STATS_AUTH_SECRET` in `.env` at it; Compose mounts it as a
secret, so the password never enters the container's environment:

```bash
mkdir -m 700 secrets
printf 'admin:%s\n' "$(openssl rand -base64 24)" > secrets/stats_auth
echo 'STATS_AUTH_SECRET=./secrets/stats_auth' >> .env
docker compose up -d
```

The file must be readable by uid 10001 (the default `0644` inside the `0700`
directory is fine); `secrets/` and `.env` are git-ignored.

Tor clients take 10-60 seconds to bootstrap. The container reports `healthy`
once HAProxy answers and at least one client has an established circuit.

Configuration
-------------

All settings are environment variables. The old lower-case names `tors`,
`test_url` and `DEBUG` are still accepted.

| Variable | Default | Meaning |
| --- | --- | --- |
| `TORS` | `10` | Number of Tor clients in the pool (1-1000). Budget roughly 60 MB RAM each. |
| `ROTATE_INTERVAL` | `600` | Seconds between rotations (jittered by ±10%). Each rotation sends `NEWNYM` to every client, then checks each one and restarts those that fail. |
| `TEST_HOST` | unset | Optional end-to-end check: a hostname resolved *through* each client at every rotation and by the Docker health check. Unset means checks are local (Tor's own status over its control socket) and generate no traffic. Resolution only; no connection is made to the host. |
| `CHECK_TIMEOUT` | `20` | Seconds to wait for a `TEST_HOST` reply. |
| `STATS_AUTH` | unset | `user:password` for the HAProxy stats page on port 4444. The page is only served when credentials exist. Password 12-256 characters, stored as a SHA-512 crypt hash. |
| `STATS_AUTH_FILE` | unset | Path to a file holding `user:password` (one line). Preferred over `STATS_AUTH`: the secret then appears in neither `docker inspect` nor the process environment. Works with Compose `secrets:`. |
| `LOG_CONNECTIONS` | `false` | Log every client connection through HAProxy (source address, timing, bytes). Off by default; see Hardening. |
| `MAX_CONNS_PER_SOURCE` | unset | Concurrent connections allowed per client address; further connections are closed. Unset means unlimited. Note that connections from the Docker host itself all share the bridge gateway address. |
| `HAPROXY_MAXCONN` | `1024` | Total concurrent client connections HAProxy accepts. |
| `TOR_SANDBOX` | `true` | Run each Tor client under Tor's seccomp syscall sandbox. Disable if Tor fails to start with options you added via `TOR_EXTRA_ARGS` or a mounted torrc. |
| `TOR_LOG_LEVEL` | `warn` | Tor log level: `debug`, `info`, `notice`, `warn`, `err`. `notice` restores bootstrap progress lines. |
| `TOR_NEW_CIRCUIT_PERIOD` | `15` | Tor `NewCircuitPeriod` (seconds). |
| `TOR_MAX_CIRCUIT_DIRTINESS` | `15` | Tor `MaxCircuitDirtiness` (seconds). Lower values rotate exit IPs faster. |
| `TOR_CIRCUIT_BUILD_TIMEOUT` | `5` | Tor `CircuitBuildTimeout` (seconds, adaptive initial value). |
| `TOR_USE_ENTRY_GUARDS` | `false` | Tor `UseEntryGuards`. Off reproduces the previous behaviour (more varied entry nodes); Tor's own default is on and protects better against guard-discovery attacks. Entry guards do not affect exit IP diversity. |
| `TOR_EXTRA_ARGS` | unset | Extra Tor command-line options appended to every instance, shell-quoted, e.g. `--ExitNodes {us} --StrictNodes 1`. Never written to the logs. |
| `LOG_LEVEL` | `info` | Supervisor log level: `debug`, `info`, `warn`, `error`. |
| `DATA_DIR` | `/var/lib/tor` | Tor state (one sub-directory per client). |
| `RUNTIME_DIR` | `/run/tor-proxy` | Control sockets and the rendered `haproxy.cfg`. |

For anything beyond that, mount a `torrc` at `/etc/tor/torrc` (read-only).
Command-line options above take precedence over it. Pluggable transports
(bridges with `ClientTransportPlugin`) are not available: the image does not
ship them and Tor runs with `NoExec`.

Mounts: the container runs as uid/gid `10001`, so any tmpfs or volume mounted
over `/var/lib/tor` or `/run/tor-proxy` needs `uid=10001,gid=10001,mode=0700`.
The container refuses to start, with a message saying so, if it cannot write
there. Without mounts the image's own writable layer is used, which also works.

Hardening
---------

What someone learns from each surface, with the defaults.

**Logs.** No client activity is recorded: HAProxy does not log connections
(`LOG_CONNECTIONS=true` turns that on), Tor runs at `warn` with
`SafeLogging` (addresses appear as `[scrubbed]`), and the supervisor never
prints credentials or `TOR_EXTRA_ARGS`. Startup banners with Tor, OpenSSL,
libevent and HAProxy versions are suppressed. What remains: the supervisor's
own lines (instance count, rotation times, restarts), HAProxy backend
up/down transitions, and Tor warnings, which on network trouble can name the
relays a client failed to reach. Bound retention on the host
(`--log-opt max-size`, as in the examples) and treat the log stream as
describing the deployment, not its users.

**Port 9050.** Only connections whose first byte is a SOCKS5 version marker
reach Tor. HTTP, SOCKS4 and TLS probes, and connections that send nothing
for five seconds, are closed without a reply. Tor would otherwise answer an
HTTP probe with a page naming itself. Once a real SOCKS5 session is
established, Tor's SOCKS implementation is still recognisable as Tor (it
supports the `RESOLVE` extension, for one); this is a proxy, and whoever can
reach it can use it. Publish it on loopback or behind a firewall or VPN, and
set `MAX_CONNS_PER_SOURCE` and `HAPROXY_MAXCONN` to cap abuse.

**Port 4444.** Not bound at all unless credentials are configured. With
credentials: HTTP basic auth against a SHA-512 hash, realm `restricted`,
HAProxy version hidden, any path other than `/haproxy` is a 404 whether or not
you are authenticated, and more than ten failed requests per minute from one
address earns 429s. The page itself still shows backend names and traffic
counters, so treat it as internal.

**Inside the container.** Everything runs as uid 10001 with every capability
dropped, `no-new-privileges`, a read-only root filesystem and two tmpfs
mounts (`noexec,nosuid,nodev`). Each Tor client additionally runs under Tor's
seccomp sandbox with `NoExec` and `DisableDebuggerAttachment`. Tor is
controlled over Unix sockets in a `0700` directory with cookie authentication;
no TCP control ports exist. Children receive a scrubbed environment. The
rendered `haproxy.cfg` holds only a password hash. Tor state lives in RAM and
disappears with the container. The image keeps BusyBox so `docker exec` works
for debugging; remove it in a derived image if you want a shell-less target.

**Network.** With defaults the container makes no requests of its own apart
from Tor's directory and circuit traffic: health checks read Tor's status over
the control socket. Setting `TEST_HOST` adds a periodic DNS resolution through
each client's exit. Rotation timing is jittered.

**Anonymity caveat.** This is an IP-rotation tool. Many parallel Tor clients
with short-lived circuits (and entry guards disabled by default) trade some
of Tor's anonymity properties for throughput and address diversity. Do not
rely on it where your own anonymity matters.

Operations
----------

* `docker stop` finishes in well under a second: the supervisor forwards
  SIGTERM to every child and waits for them.
* If a Tor client or HAProxy crashes, the supervisor restarts it with
  exponential back-off (1 s doubling to 60 s). HAProxy stops routing to a
  client the moment it stops answering SOCKS5 greetings (`check inter 10s`).
* At every rotation an instance counts as healthy when Tor reports bootstrap
  100%, an established circuit and network liveness (plus a successful
  `TEST_HOST` resolution if configured). Fresh instances get 180 s of grace.
  Unhealthy ones are restarted.
* The Docker `HEALTHCHECK` runs every 60 s with a 120 s start period and is
  local unless `TEST_HOST` is set.
* Rotation and check results are logged at `info`, for example
  `supervisor: 8/8 instances healthy`.

Development
-----------

```bash
docker build -t tor-rotating-proxy:dev .
ruby -wc tor_proxy.rb start.rb healthcheck.rb
docker run --rm -i hadolint/hadolint hadolint - < Dockerfile
```

CI runs hadolint, a Trivy scan and a smoke test of the hardened container on
every change and weekly; Dependabot proposes base-image and action updates.

Files: [Dockerfile](Dockerfile), [tor_proxy.rb](tor_proxy.rb) (supervisor,
config, SOCKS5 and control-port clients), [start.rb](start.rb),
[healthcheck.rb](healthcheck.rb), [haproxy.cfg.erb](haproxy.cfg.erb),
[compose.yaml](compose.yaml).

Further reading
---------------

* [Tor manual](https://2019.www.torproject.org/docs/tor-manual.html.en)
* [Tor control protocol](https://spec.torproject.org/control-spec/)
* [HAProxy configuration manual](https://docs.haproxy.org/)

--------------

Thanks to mattes/rotating-proxy, which this project forked long ago.
