# frozen_string_literal: true

# tor-rotating-proxy
#
# Supervises a pool of Tor clients behind an HAProxy SOCKS5 front end,
# periodically asks every instance for fresh circuits (NEWNYM) and replaces
# instances that stop working. Standard library only; no gems required.
#
# Process model: this file's Supervisor runs as PID 1 inside the container.
# It spawns Tor and HAProxy as direct children (nothing daemonizes), reaps
# them, restarts them with back-off if they die and shuts everything down
# cleanly on SIGTERM so `docker stop` is fast.
#
# Threat model: the container may run where its logs, its ports and even its
# filesystem are visible to an adversary. Defaults therefore log no client
# activity, expose no management surface without credentials, keep secrets
# hashed, answer only well-formed SOCKS5 on the proxy port and make no
# external requests of their own.

require 'erb'
require 'fileutils'
require 'io/wait'
require 'logger'
require 'securerandom'
require 'shellwords'
require 'socket'
require 'time'
require 'uri'

module TorProxy
  SOCKS_PORT    = 9050    # HAProxy SOCKS5 front end (the published port)
  STATS_PORT    = 4444    # HAProxy statistics page (only bound when credentials are set)
  TOR_BASE_PORT = 10_000  # Tor instance N listens on 127.0.0.1:(TOR_BASE_PORT + N)
  MAX_TORS      = 1_000

  class ConfigError  < StandardError; end
  class ControlError < StandardError; end

  # Stdout is a pipe under Docker and would otherwise be block-buffered: lines
  # would reach `docker logs` late, and be lost entirely on a crash.
  $stdout.sync = true
  LOG = Logger.new($stdout)
  LOG.formatter = lambda do |severity, time, _progname, msg|
    "#{time.utc.iso8601(3)} [#{severity.downcase}] supervisor: #{msg}\n"
  end

  module Util
    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.ensure_dir(path)
      FileUtils.mkdir_p(path, mode: 0o700)
    rescue SystemCallError => e
      raise ConfigError, "cannot create directory #{path}: #{e.message}"
    end

    # Fail with an actionable message when a volume or tmpfs was mounted over
    # one of our directories without making it ours (Docker mounts an
    # option-less tmpfs as root-owned, which uid 10001 cannot write to).
    def self.writable_dir(path)
      ensure_dir(path)
      return if File.writable?(path)

      raise ConfigError, "#{path} is not writable by uid #{Process.euid}; mount it with " \
                         "uid=#{Process.euid},gid=#{Process.egid},mode=0700 (see README)"
    end

    # A directory accessible only by our user. Tor insists on this for its
    # DataDirectory and for the directory that holds its control socket.
    def self.private_dir(path)
      ensure_dir(path)
      stat = File.stat(path)
      unless stat.uid == Process.euid
        raise ConfigError, "#{path} is owned by uid #{stat.uid} but we run as uid #{Process.euid}; " \
                           "mount it with uid=#{Process.euid},gid=#{Process.egid},mode=0700"
      end
      File.chmod(0o700, path) unless (stat.mode & 0o077).zero?
    end

    # SHA-512 crypt(3) hash, the format HAProxy userlists verify. The clear
    # text password never reaches the rendered configuration.
    def self.crypt_sha512(password)
      salt = SecureRandom.alphanumeric(16)
      hash = password.crypt("$6$#{salt}")
      raise ConfigError, 'this platform cannot produce SHA-512 crypt hashes' unless hash.start_with?("$6$#{salt}$")

      hash
    end

    # +interval+ plus or minus 10%, so rotations do not happen on a clockwork
    # schedule an observer could set a watch by.
    def self.jitter(interval)
      interval * (0.9 + (Random.rand * 0.2))
    end
  end

  # Configuration from environment variables. The lower-case names used by
  # older versions of this image (tors, test_url, DEBUG) are still accepted.
  class Config
    attr_reader :tors, :rotate_interval, :check_timeout, :test_host, :maxconn,
                :stats_user, :stats_password_hash, :log_connections, :max_conns_per_source,
                :data_dir, :runtime_dir, :tor_log_level, :tor_sandbox, :tor_options, :tor_extra_args

    def self.from_env(env = ENV)
      new(env)
    end

    def initialize(env)
      LOG.level             = log_level(env)
      @tors                 = integer(env, 'TORS', default: 10, range: 1..MAX_TORS, fallback: env['tors'])
      @rotate_interval      = integer(env, 'ROTATE_INTERVAL', default: 600, range: 10..86_400)
      @check_timeout        = integer(env, 'CHECK_TIMEOUT', default: 20, range: 1..300)
      @maxconn              = integer(env, 'HAPROXY_MAXCONN', default: 1024, range: 1..1_000_000)
      @max_conns_per_source = integer(env, 'MAX_CONNS_PER_SOURCE', default: nil, range: 1..1_000_000)
      @test_host            = hostname('TEST_HOST', env['TEST_HOST'] || env['test_url'])
      @log_connections      = boolean('LOG_CONNECTIONS', env.fetch('LOG_CONNECTIONS', 'false'))
      @stats_user, @stats_password_hash = stats_credentials(env)
      @data_dir             = env.fetch('DATA_DIR', '/var/lib/tor')
      @runtime_dir          = env.fetch('RUNTIME_DIR', '/run/tor-proxy')
      @tor_log_level        = one_of('TOR_LOG_LEVEL', env.fetch('TOR_LOG_LEVEL', 'warn'), %w[debug info notice warn err])
      @tor_sandbox          = boolean('TOR_SANDBOX', env.fetch('TOR_SANDBOX', 'true'))
      @tor_options = {
        'NewCircuitPeriod'    => integer(env, 'TOR_NEW_CIRCUIT_PERIOD', default: 15, range: 1..3600),
        'MaxCircuitDirtiness' => integer(env, 'TOR_MAX_CIRCUIT_DIRTINESS', default: 15, range: 1..86_400),
        'CircuitBuildTimeout' => integer(env, 'TOR_CIRCUIT_BUILD_TIMEOUT', default: 5, range: 1..600),
        'UseEntryGuards'      => boolean('TOR_USE_ENTRY_GUARDS', env.fetch('TOR_USE_ENTRY_GUARDS', 'false')) ? 1 : 0
      }
      @tor_extra_args = extra_args(env.fetch('TOR_EXTRA_ARGS', ''))
    end

    def stats_enabled?
      !stats_user.nil?
    end

    # Human-readable summary for the startup log. Never includes credentials
    # or the content of TOR_EXTRA_ARGS (which may carry bridge lines).
    def to_s
      tor = tor_options.map { |k, v| "#{k}=#{v}" }.join(' ')
      "tors=#{tors} rotate_interval=#{rotate_interval}s stats=#{stats_enabled? ? 'auth' : 'off'} " \
        "log_connections=#{log_connections} max_conns_per_source=#{max_conns_per_source || 'unlimited'} " \
        "test_host=#{test_host || 'none'} sandbox=#{tor_sandbox} #{tor} extra_args=#{tor_extra_args.size}"
    end

    private

    def integer(env, name, default:, range:, fallback: nil)
      raw = env[name] || fallback
      return default if raw.nil? || raw.strip.empty?

      value = begin
        Integer(raw.strip, 10)
      rescue ArgumentError
        raise ConfigError, "#{name} must be an integer, got #{raw.inspect}"
      end
      raise ConfigError, "#{name} must be between #{range.min} and #{range.max}, got #{value}" unless range.cover?(value)

      value
    end

    def boolean(name, raw)
      case raw.to_s.strip.downcase
      when '1', 'true', 'yes', 'on'       then true
      when '0', 'false', 'no', 'off', '' then false
      else raise ConfigError, "#{name} must be true or false, got #{raw.inspect}"
      end
    end

    def one_of(name, raw, allowed)
      value = raw.to_s.strip.downcase
      raise ConfigError, "#{name} must be one of #{allowed.join(', ')}, got #{raw.inspect}" unless allowed.include?(value)

      value
    end

    HOSTNAME = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/i

    # Accepts a bare hostname, or a URL for backwards compatibility. Empty
    # means "no external check".
    def hostname(name, raw)
      return nil if raw.nil? || raw.strip.empty?

      host = raw.include?('://') ? URI.parse(raw).host : raw.strip
      raise ConfigError, "#{name} is not a valid hostname: #{raw.inspect}" unless host&.match?(HOSTNAME) && host.bytesize <= 253

      host
    rescue URI::InvalidURIError
      raise ConfigError, "#{name} is not a valid hostname or URL: #{raw.inspect}"
    end

    # "user:password" from STATS_AUTH, or from the file named by
    # STATS_AUTH_FILE (Docker/Compose secrets). Returns [user, sha512-crypt
    # hash]; the stats page is only served when credentials are present.
    def stats_credentials(env)
      inline = env['STATS_AUTH'].to_s
      path   = env['STATS_AUTH_FILE'].to_s
      raise ConfigError, 'set STATS_AUTH or STATS_AUTH_FILE, not both' if !inline.empty? && !path.empty?

      raw = path.empty? ? inline : read_secret(path)
      return [nil, nil] if raw.empty?

      user, password = raw.split(':', 2)
      raise ConfigError, 'STATS_AUTH must be user:password' if password.nil?
      raise ConfigError, 'STATS_AUTH user must be 1-64 characters from A-Z a-z 0-9 _ . @ -' unless user.match?(/\A[A-Za-z0-9_.@-]{1,64}\z/)
      raise ConfigError, 'STATS_AUTH password must be 12-256 characters' unless (12..256).cover?(password.length)
      raise ConfigError, 'STATS_AUTH password must not contain control characters' if password.match?(/[[:cntrl:]]/)

      [user, Util.crypt_sha512(password)]
    end

    def read_secret(path)
      File.read(path, encoding: 'UTF-8').sub(/\r?\n\z/, '')
    rescue Errno::EACCES
      raise ConfigError, "cannot read STATS_AUTH_FILE #{path}: permission denied for uid #{Process.euid}; " \
                         'make the file readable by that uid (for example chmod 0644 inside a 0700 directory)'
    rescue SystemCallError => e
      raise ConfigError, "cannot read STATS_AUTH_FILE #{path}: #{e.message}"
    end

    def extra_args(raw)
      Shellwords.split(raw)
    rescue ArgumentError => e
      raise ConfigError, "TOR_EXTRA_ARGS: #{e.message}"
    end

    def log_level(env)
      raw = env['LOG_LEVEL'] || (env['DEBUG'] ? 'debug' : 'info')
      { 'debug' => Logger::DEBUG, 'info' => Logger::INFO, 'warn' => Logger::WARN, 'error' => Logger::ERROR }
        .fetch(raw.to_s.strip.downcase) { raise ConfigError, "LOG_LEVEL must be debug, info, warn or error, got #{raw.inspect}" }
    end
  end

  # Minimal SOCKS5 client for health checks: method negotiation without
  # authentication, and Tor's RESOLVE extension (command 0xF0). A successful
  # RESOLVE proves an instance has a working circuit and a cooperating exit,
  # without ever opening a connection to a third-party server.
  module Socks5
    class Error < StandardError; end

    VERSION       = 0x05
    NO_AUTH       = 0x00
    CMD_RESOLVE   = 0xF0
    ATYP_IPV4     = 0x01
    ATYP_DOMAIN   = 0x03
    ATYP_IPV6     = 0x04
    REPLY_SUCCESS = 0x00
    REPLY_TEXT = {
      0x01 => 'general SOCKS server failure', 0x02 => 'connection not allowed',
      0x03 => 'network unreachable',          0x04 => 'host unreachable',
      0x05 => 'connection refused',           0x06 => 'TTL expired',
      0x07 => 'command not supported',        0x08 => 'address type not supported'
    }.freeze

    # Connects and completes method negotiation only. Proves something that
    # speaks SOCKS5 is listening. Raises Socks5::Error otherwise.
    def self.greet(proxy_host, proxy_port, timeout: 5)
      deadline = Util.now + timeout
      Socket.tcp(proxy_host, proxy_port, connect_timeout: timeout) { |sock| handshake(sock, deadline) }
      true
    rescue SystemCallError, IOError => e
      raise Error, e.message
    end

    # Returns the resolved IP address as a String, or raises Socks5::Error.
    def self.resolve(proxy_host, proxy_port, name, timeout: 20)
      raise Error, 'hostname too long for SOCKS5' if name.bytesize > 255

      deadline = Util.now + timeout
      Socket.tcp(proxy_host, proxy_port, connect_timeout: timeout) do |sock|
        handshake(sock, deadline)
        sock.write([VERSION, CMD_RESOLVE, 0, ATYP_DOMAIN, name.bytesize].pack('C5') + name.b + [0].pack('n'))
        version, reply, _reserved, atyp = read_exact(sock, 4, deadline).unpack('C4')
        raise Error, "unexpected reply version #{version}" unless version == VERSION
        raise Error, REPLY_TEXT.fetch(reply, "reply code #{reply}") unless reply == REPLY_SUCCESS

        case atyp
        when ATYP_IPV4 then read_exact(sock, 4, deadline).unpack('C4').join('.')
        when ATYP_IPV6 then read_exact(sock, 16, deadline).unpack('n8').map { |g| g.to_s(16) }.join(':')
        else raise Error, "unexpected address type #{atyp}"
        end
      end
    rescue SystemCallError, IOError => e
      raise Error, e.message
    end

    def self.handshake(sock, deadline)
      sock.write([VERSION, 1, NO_AUTH].pack('C3'))
      version, method = read_exact(sock, 2, deadline).unpack('C2')
      raise Error, "unexpected greeting #{version}/#{method}" unless version == VERSION && method == NO_AUTH
    end
    private_class_method :handshake

    def self.read_exact(sock, count, deadline)
      buffer = ''.b
      while buffer.bytesize < count
        remaining = deadline - Util.now
        raise Error, 'timed out waiting for reply' if remaining <= 0 || !sock.wait_readable(remaining)

        chunk = sock.read_nonblock(count - buffer.bytesize, exception: false)
        case chunk
        when nil            then raise Error, 'connection closed by proxy'
        when :wait_readable then next
        else buffer << chunk
        end
      end
      buffer
    end
    private_class_method :read_exact
  end

  # A supervised child process.
  class Service
    attr_reader :name
    attr_accessor :pid, :started_at, :failures, :expected_exit

    def initialize(name)
      @name = name
      @pid = nil
      @failures = 0
      @expected_exit = false
    end

    def running?
      !pid.nil?
    end

    def uptime
      started_at ? Util.now - started_at : Float::INFINITY
    end

    def prepare; end

    def command
      raise NotImplementedError
    end

    # What the debug log shows for this command. Override to redact.
    def command_for_log
      command.shelljoin
    end

    # Children get a scrubbed environment: no reason for Tor or HAProxy to see
    # STATS_AUTH or anything else we were started with.
    def child_env
      { 'PATH' => ENV.fetch('PATH', '/usr/local/bin:/usr/bin:/bin') }
    end

    def spawn
      prepare
      LOG.debug { "exec: #{command_for_log}" }
      @expected_exit = false
      @started_at = Util.now
      @pid = Process.spawn(child_env, *command, unsetenv_others: true, in: File::NULL, out: $stdout, err: $stderr)
    end
  end

  class Tor < Service
    # A freshly started instance gets this long to bootstrap before failing
    # checks count against it.
    BOOTSTRAP_GRACE = 180

    attr_reader :id

    def initialize(id, config)
      super("tor-#{id}")
      @id = id
      @config = config
    end

    def socks_port
      TOR_BASE_PORT + id
    end

    def data_dir
      File.join(@config.data_dir, id.to_s)
    end

    def control_socket
      File.join(@config.runtime_dir, 'control', "#{id}.sock")
    end

    def cookie_file
      File.join(data_dir, 'control_auth_cookie')
    end

    def prepare
      Util.private_dir(File.dirname(control_socket))
      Util.private_dir(data_dir)
      File.unlink(control_socket) if File.socket?(control_socket) # left behind by a crashed instance
    end

    # Tor looks for ~/.torrc before its configuration is parsed and warns when
    # HOME is unset. Point it at this instance's private directory.
    def child_env
      super.merge('HOME' => data_dir)
    end

    def base_command
      [
        'tor',
        '--quiet',                              # no console logging before --Log below takes effect
        '--SocksPort', "127.0.0.1:#{socks_port}",
        '--ControlSocket', control_socket,      # Unix socket in a 0700 directory ...
        '--CookieAuthentication', '1',          # ... and cookie-authenticated on top
        '--DataDirectory', data_dir,
        '--ClientOnly', '1',
        '--AvoidDiskWrites', '1',
        '--RunAsDaemon', '0',
        '--Log', "#{@config.tor_log_level} stdout",
        '--SafeLogging', '1',                   # addresses in log lines appear as [scrubbed]
        '--NoExec', '1',                        # never launch helper processes
        '--DisableDebuggerAttachment', '1',
        '--Sandbox', @config.tor_sandbox ? '1' : '0' # seccomp syscall filter
      ].tap { |args| @config.tor_options.each { |option, value| args.push("--#{option}", value.to_s) } }
    end

    def command
      base_command + @config.tor_extra_args
    end

    def command_for_log
      extra = @config.tor_extra_args.empty? ? '' : " [#{@config.tor_extra_args.size} extra args redacted]"
      base_command.shelljoin + extra
    end

    # Ask this instance to switch to clean circuits.
    def newnym
      control { |sock| control_command(sock, 'SIGNAL NEWNYM') }
    end

    # Tor's own view of itself, from the control socket. No network traffic.
    def status
      lines = control do |sock|
        control_command(sock, 'GETINFO status/bootstrap-phase status/circuit-established network-liveness')
      end
      info = lines.to_h { |line| line.split('=', 2) }
      {
        progress: info['status/bootstrap-phase'].to_s[/PROGRESS=(\d+)/, 1].to_i,
        circuit:  info['status/circuit-established'] == '1',
        live:     info['network-liveness'] == 'up'
      }
    end

    # Local check by default; an end-to-end RESOLVE through the instance only
    # when TEST_HOST is configured.
    def healthy?
      st = status
      unless st[:progress] == 100 && st[:circuit] && st[:live]
        return still_bootstrapping("#{st[:progress]}% bootstrapped") if uptime < BOOTSTRAP_GRACE

        LOG.warn "#{name}: unhealthy (bootstrap #{st[:progress]}%, circuit #{st[:circuit] ? 'yes' : 'no'}, " \
                 "network #{st[:live] ? 'up' : 'down'})"
        return false
      end
      return true unless @config.test_host

      address = Socks5.resolve('127.0.0.1', socks_port, @config.test_host, timeout: @config.check_timeout)
      LOG.debug { "#{name}: resolved #{@config.test_host} to #{address}" }
      true
    rescue ControlError, Socks5::Error => e
      return still_bootstrapping(e.message) if uptime < BOOTSTRAP_GRACE

      LOG.warn "#{name}: health check failed: #{e.message}"
      false
    end

    private

    def still_bootstrapping(detail)
      LOG.debug { "#{name}: not ready yet (#{detail}), #{uptime.round}s old" }
      true
    end

    # Opens an authenticated control connection and yields it.
    def control
      cookie = File.binread(cookie_file).unpack1('H*')
      UNIXSocket.open(control_socket) do |sock|
        control_command(sock, "AUTHENTICATE #{cookie}")
        result = yield sock
        sock.write("QUIT\r\n")
        result
      end
    rescue SystemCallError, IOError => e
      raise ControlError, e.message
    end

    # Sends one command and returns its data lines ("250-key=value" without the
    # status prefix). Raises ControlError on any non-250 reply.
    def control_command(sock, line)
      sock.write("#{line}\r\n")
      data = []
      loop do
        reply = read_control_line(sock)
        status, separator, text = reply[0, 3], reply[3], reply[4..].to_s
        raise ControlError, "control reply to #{line.split.first}: #{reply}" unless status == '250'

        case separator
        when '-' then data << text
        when '+' then data << text while (text = read_control_line(sock)) != '.'
        else return data
        end
      end
    end

    def read_control_line(sock)
      raise ControlError, 'timed out waiting for control reply' unless sock.wait_readable(5)

      reply = sock.gets
      raise ControlError, 'control connection closed' if reply.nil?

      reply.chomp
    end
  end

  class HAProxy < Service
    def initialize(config, tors)
      super('haproxy')
      @config = config
      @tors = tors
    end

    def config_path
      File.join(@config.runtime_dir, 'haproxy.cfg')
    end

    def template_path
      File.join(__dir__, 'haproxy.cfg.erb')
    end

    def prepare
      Util.ensure_dir(@config.runtime_dir)
      File.open(config_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(render) }
      File.chmod(0o600, config_path)
    end

    # -q keeps HAProxy's version banner and other startup chatter out of the logs.
    def command
      ['haproxy', '-q', '-f', config_path]
    end

    # Validate the rendered configuration before anything is started, so a
    # mistake fails the container immediately instead of crash-looping.
    def check!
      prepare
      return if system(child_env, 'haproxy', '-c', '-q', '-f', config_path, unsetenv_others: true)

      raise ConfigError, 'haproxy rejected the generated configuration (see messages above)'
    end

    private

    def render
      backends = @tors.map { |tor| { name: tor.name, addr: '127.0.0.1', port: tor.socks_port } }
      ERB.new(File.read(template_path), trim_mode: '-').result_with_hash(
        port: SOCKS_PORT, stats_port: STATS_PORT, maxconn: @config.maxconn, backends: backends,
        log_connections: @config.log_connections, max_conns_per_source: @config.max_conns_per_source,
        stats_user: @config.stats_user, stats_password_hash: @config.stats_password_hash
      )
    end
  end

  class Supervisor
    STOP_TIMEOUT = 8 # seconds; Docker's default grace period before SIGKILL is 10

    def initialize(config)
      @config = config
      @tors = Array.new(config.tors) { |id| Tor.new(id, config) }
      @haproxy = HAProxy.new(config, @tors)
      @children = {}   # pid => Service
      @restart_at = {} # Service => monotonic time at which to start it again
      @stopping = false
      @wake_r, @wake_w = IO.pipe
    end

    def run
      LOG.info "tor-rotating-proxy starting as uid #{Process.euid}: #{@config}"
      Util.writable_dir(@config.runtime_dir)
      Util.writable_dir(@config.data_dir)
      @haproxy.check!
      trap_signals
      @tors.each { |tor| start(tor) }
      start(@haproxy)
      next_rotation = Util.now + Util.jitter(@config.rotate_interval)

      until @stopping
        wait_until([next_rotation, *@restart_at.values].min)
        reap
        break if @stopping

        start_due
        next unless Util.now >= next_rotation

        rotate
        next_rotation = Util.now + Util.jitter(@config.rotate_interval)
      end
      shutdown
    end

    private

    # Signal handlers only set a flag and poke the self-pipe; all the work
    # happens in the main loop.
    def trap_signals
      %w[TERM INT].each do |sig|
        trap(sig) do
          @stopping = true
          wake
        end
      end
      trap('CHLD') { wake }
    end

    def wake
      @wake_w.write_nonblock('.', exception: false)
    end

    def wait_until(deadline)
      wait(deadline - Util.now)
    end

    def wait(timeout)
      IO.select([@wake_r], nil, nil, timeout) if timeout.positive?
      @wake_r.read_nonblock(1024, exception: false)
    end

    def start(service)
      service.spawn
      @children[service.pid] = service
      LOG.info "started #{service.name} (pid #{service.pid})"
    rescue SystemCallError => e
      LOG.error "cannot start #{service.name}: #{e.message}"
      schedule_restart(service)
    end

    def reap
      loop do
        pid, status = Process.wait2(-1, Process::WNOHANG)
        break if pid.nil?

        service = @children.delete(pid)
        next if service.nil?

        service.pid = nil
        exited(service, status)
      end
    rescue Errno::ECHILD
      nil
    end

    def exited(service, status)
      reason = status.exited? ? "exit status #{status.exitstatus}" : "signal #{status.termsig}"
      if service.expected_exit || @stopping
        LOG.info "#{service.name} stopped (#{reason})"
      else
        LOG.warn "#{service.name} died unexpectedly (#{reason})"
        schedule_restart(service)
      end
    end

    # Exponential back-off for crash loops, reset after 30s of healthy uptime.
    def schedule_restart(service)
      crashed_quickly = service.started_at && (Util.now - service.started_at) < 30
      service.failures = crashed_quickly ? service.failures + 1 : 0
      delay = [2**service.failures, 60].min
      LOG.info "restarting #{service.name} in #{delay}s"
      @restart_at[service] = Util.now + delay
    end

    def start_due
      @restart_at.select { |_, at| at <= Util.now }.each_key do |service|
        @restart_at.delete(service)
        start(service)
      end
    end

    def rotate
      LOG.info 'rotating circuits (NEWNYM) on all instances'
      @tors.select(&:running?).each do |tor|
        tor.newnym
      rescue ControlError => e
        LOG.warn "#{tor.name}: NEWNYM failed: #{e.message}"
      end

      LOG.info @config.test_host ? "checking every instance (local status and resolving #{@config.test_host})" : 'checking every instance (local status)'
      results = @tors.select(&:running?).map { |tor| Thread.new { [tor, tor.healthy?] } }.map(&:value)
      unhealthy = results.reject { |_, ok| ok }.map(&:first)
      LOG.info "#{results.size - unhealthy.size}/#{results.size} instances healthy"
      return if unhealthy.empty? || @stopping

      LOG.warn "restarting #{unhealthy.map(&:name).join(', ')}"
      stop(unhealthy)
      unhealthy.each { |tor| start(tor) } unless @stopping
    end

    # SIGTERM, then SIGKILL for anything still alive after +timeout+ seconds.
    def stop(services, timeout: STOP_TIMEOUT)
      services = services.select(&:running?)
      services.each do |service|
        service.expected_exit = true
        signal(service.pid, 'TERM')
      end
      wait_for_exit(services, timeout)

      stragglers = services.select(&:running?)
      stragglers.each do |service|
        LOG.warn "#{service.name} ignored SIGTERM, sending SIGKILL"
        signal(service.pid, 'KILL')
      end
      wait_for_exit(stragglers, 2)
    end

    def wait_for_exit(services, timeout)
      deadline = Util.now + timeout
      while services.any?(&:running?) && Util.now < deadline
        wait([deadline - Util.now, 0.2].min)
        reap
      end
    end

    def signal(pid, sig)
      Process.kill(sig, pid)
    rescue Errno::ESRCH
      nil
    end

    def shutdown
      LOG.info 'shutting down'
      stop(@children.values)
      LOG.info 'stopped'
    end
  end
end
