# tor-rotating-proxy: a load-balanced pool of Tor SOCKS5 clients.
#
# Single stage on purpose: there is nothing to compile. Everything (Ruby, Tor,
# HAProxy) comes from the Alpine 3.24 repositories, so one `docker build`
# picks up all of Alpine's security updates, and the image stays ~50 MB.
# The base is pinned by digest; Dependabot keeps the pin current.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

LABEL org.opencontainers.image.title="tor-rotating-proxy" \
      org.opencontainers.image.description="Load-balanced pool of Tor SOCKS5 proxies with automatic circuit rotation" \
      org.opencontainers.image.source="https://github.com/shaddysignal/tor-rotating-proxy" \
      org.opencontainers.image.licenses="Unlicense"

# Package versions follow the Alpine 3.24 branch rather than being pinned
# exactly: Alpine removes superseded packages from its index, so exact pins
# break the build at the very moment a security update lands.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache \
 && apk add --no-cache ruby tor haproxy \
 && addgroup -S -g 10001 proxy \
 && adduser -S -D -H -u 10001 -G proxy -s /sbin/nologin -g 'tor-rotating-proxy' proxy \
 && install -d -o proxy -g proxy -m 0700 /var/lib/tor /run/tor-proxy

WORKDIR /opt/tor-proxy
COPY --chown=root:root --chmod=0644 tor_proxy.rb haproxy.cfg.erb ./
COPY --chown=root:root --chmod=0755 start.rb healthcheck.rb ./

USER 10001:10001

# 9050: SOCKS5 front end. 4444: HAProxy stats page (publish only where trusted).
EXPOSE 9050/tcp 4444/tcp

# Resolves TEST_HOST through the pool; start-period covers Tor bootstrapping.
HEALTHCHECK --interval=60s --timeout=30s --start-period=120s --retries=3 \
  CMD ["ruby", "/opt/tor-proxy/healthcheck.rb"]

ENTRYPOINT ["ruby", "/opt/tor-proxy/start.rb"]
