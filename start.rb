#!/usr/bin/env ruby
# frozen_string_literal: true

# Container entry point: supervise the Tor pool and HAProxy. See tor_proxy.rb.

require_relative 'tor_proxy'

begin
  TorProxy::Supervisor.new(TorProxy::Config.from_env).run
rescue TorProxy::ConfigError => e
  TorProxy::LOG.error e.message
  exit 2
end
