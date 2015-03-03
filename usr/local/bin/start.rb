#!/usr/bin/env ruby
require 'erb'
require 'excon'
require 'logger'

$logger = Logger.new(STDOUT, Logger::INFO)

module Service
  class Base
    attr_reader :port

    def initialize(port)
      @port = port
    end

    def service_name
      self.class.name.downcase
    end

    def start
      ensure_directories
      $logger.info "starting #{service_name} on port #{port}"
    end

    def ensure_directories
      %w{lib run log}.each do |dir|
        path = "/var/#{dir}/#{service_name}"
        Dir.mkdir(path) unless Dir.exists?(path)
      end
    end

    def data_directory
      "/var/lib/#{service_name}"
    end

    def pid_file
      "/var/run/#{service_name}/#{port}.pid"
    end

    def executable
      self.class.which(service_name)
    end

    def stop
      $logger.info "stopping #{service_name} on port #{port}"
      if File.exists?(pid_file)
        pid = File.read(pid_file).strip
        self.class.kill(pid)
      else
        $logger.info "#{service_name} on port #{port} was not running"
      end
    end

    def self.kill(pid, signal='SIGINT')
      Process.kill(signal, pid)
    end

    def self.fire_and_forget(*args)
      pid = Process.fork
      if pid.nil? then
        # In child
        exec args.join(" ")
      else
        # In parent
        Process.detach(pid)
      end
    end

    def self.which(executable)
      path = `which #{executable}`.strip
      if path == ""
        return nil
      else
        return path
      end
    end
  end


  class Tor < Base
    def start
      super
      self.class.fire_and_forget(executable,
        "--SocksPort #{port}",
        "--NewCircuitPeriod 120",
        "--DataDirectory #{data_directory}",
        "--PidFile #{pid_file}",
        "--Log \"warn syslog\"",
        '--RunAsDaemon 1',
        "| logger -t 'tor' 2>&1")
    end
  end

  class Polipo < Base
    def initialize(port, tor:)
      super(port)
      @tor = tor
    end

    def start
      super
      # https://gitweb.torproject.org/torbrowser.git/blob_plain/1ffcd9dafb9dd76c3a29dd686e05a71a95599fb5:/build-scripts/config/polipo.conf
      self.class.fire_and_forget(executable,
        "proxyPort=#{port}",
        "socksParentProxy=127.0.0.1:#{tor_port}",
        "socksProxyType=socks5",
        "diskCacheRoot=''",
        "disableLocalInterface=true",
        "allowedClients=127.0.0.1",
        "localDocumentRoot=''",
        "disableConfiguration=true",
        "dnsUseGethostbyname='yes'",
        "logSyslog=true",
        "daemonise=true",
        "pidFile=#{pid_file}",
        "disableVia=true",
        "allowedPorts='1-65535'",
        "tunnelAllowedPorts='1-65535'",
        "| logger -t 'polipo' 2>&1")
    end

    def tor_port
      @tor.port
    end
  end

  class Proxy
    attr_reader :id
    attr_reader :tor, :polipo

    def initialize(id)
      @id = id
      @tor = Tor.new(tor_port)
      @polipo = Polipo.new(polipo_port, tor: tor)
    end

    def start
      $logger.info "starting proxy id #{id}"
      @tor.start
      @polipo.start
    end

    def stop
      $logger.info "stopping proxy id #{id}"
      @tor.stop
      @polipo.stop
    end

    def tor_port
      10000 + id
    end

    def polipo_port
      tor_port + 10000
    end
    alias_method :port, :polipo_port
  end

  class Haproxy < Base
    attr_reader :backends

    def initialize(port = 5566)
      @config_erb_path = "/usr/local/etc/haproxy.cfg.erb"
      @config_path = "/usr/local/etc/haproxy.cfg"
      @backends = []
      super(port)
    end

    def start
      super
      compile_config
      self.class.fire_and_forget(executable,
        "-f #{@config_path}",
        "| logger 2>&1")
    end

    def soft_reload
      self.class.fire_and_forget(executable,
        "-f #{@config_path}",
        "-p #{pid_file}",
        "-sf #{File.read(pid_file)}",
        "| logger 2>&1")
    end

    def add_backend(backend)
      @backends << {:name => 'tor', :addr => '127.0.0.1', :port => backend.port}
    end

    private
    def compile_config
      File.write(@config_path, ERB.new(File.read(@config_erb_path)).result(binding))
    end
  end
end


haproxy = Service::Haproxy.new

tor_instances = ENV['tors'] || 10
tor_instances.to_i.times.each do |id|
  proxy = Service::Proxy.new(id)
  haproxy.add_backend(proxy)
  proxy.start
end

haproxy.start

loop do
  sleep 3600
end
