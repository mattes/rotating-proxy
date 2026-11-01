#!/usr/bin/env ruby
# frozen_string_literal: true

# Docker HEALTHCHECK. Local by default: HAProxy must answer a SOCKS5 greeting
# and at least one Tor instance must report an established circuit over its
# control socket. Only when TEST_HOST is set does it also resolve that name
# through the pool, which is the one check that generates Tor traffic.

require_relative 'tor_proxy'

$stdout.sync = true
begin
  config = TorProxy::Config.from_env
  TorProxy::Socks5.greet('127.0.0.1', TorProxy::SOCKS_PORT, timeout: 5)

  tors = Array.new(config.tors) { |id| TorProxy::Tor.new(id, config) }
  ready = tors.count do |tor|
    st = tor.status
    st[:progress] == 100 && st[:circuit]
  rescue TorProxy::ControlError
    false
  end
  raise TorProxy::ControlError, "no instance has an established circuit (0/#{tors.size})" if ready.zero?

  detail = "#{ready}/#{tors.size} instances with circuits"
  if config.test_host
    address = TorProxy::Socks5.resolve('127.0.0.1', TorProxy::SOCKS_PORT, config.test_host, timeout: config.check_timeout)
    detail += ", #{config.test_host} resolved to #{address}"
  end
  puts "healthy: #{detail}"
rescue TorProxy::ConfigError, TorProxy::ControlError, TorProxy::Socks5::Error => e
  puts "unhealthy: #{e.message}"
  exit 1
end
