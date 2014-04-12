#!/usr/bin/env ruby
require 'erb'
require 'eventmachine'

module Service

  class Base
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
    attr_reader :port, :delegated_port

    def initialize(port)
      @exec = self.class.which('tor')
      @delegated_exec = self.class.which('delegated')
      @port = port
      @tor_port = @port
      @delegated_port = @port + 10000
    end

    def start
      Dir.mkdir("/var/lib/tor") unless Dir.exists?("/var/lib/tor")
      Dir.mkdir("/var/run/tor") unless Dir.exists?("/var/run/tor")
      Dir.mkdir("/var/log/tor") unless Dir.exists?("/var/log/tor")
      self.class.fire_and_forget(@exec,
        "--SocksPort #{@tor_port}",
        "--NewCircuitPeriod 120",
        "--DataDirectory /var/lib/tor/#{@tor_port}",
        "--PidFile /var/run/tor/#{@tor_port}.pid",
        "--Log \"warn file /var/log/tor/#{@tor_port}.log\"",
        '--RunAsDaemon 1',
        "> /var/log/tor/#{@tor_port}.log 2>&1")

      Dir.mkdir("/var/lib/delegated") unless Dir.exists?("/var/lib/delegated")
      Dir.mkdir("/var/run/delegated") unless Dir.exists?("/var/run/delegated")
      Dir.mkdir("/var/log/delegated") unless Dir.exists?("/var/log/delegated")
      self.class.fire_and_forget(@delegated_exec,
        "-P#{@delegated_port}",
        "SERVER=http",
        "DGROOT=/var/lib/delegated/#{@delegated_port}",
        "SOCKS=127.0.0.1:#{@tor_port}",
        "PIDFILE=/var/run/delegated/#{@delegated_port}.pid",
        "LOGFILE=/var/log/delegated/#{@delegated_port}.log",
        "ADMIN=example@example.com",
        "DYLIB='+,lib*.so.X.Y.Z'",
        "HTTPCONF=kill-qhead:Via",
        "OWNER=root/root",
        "> /var/log/delegated/#{@delegated_port}.log 2>&1")
    end

    def stop
      if File.exists?("/var/run/tor/#{@tor_port}.pid")
        tor_pid = IO.read("/var/run/tor/#{@tor_port}.pid").strip()
        self.class.kill(tor_pid)
      end

      if File.exists?("/var/run/delegated/#{@delegated_port}.pid")
        delegated_pid = IO.read("/var/run/delegated/#{@delegated_port}.pid").strip()
        self.class.kill(delegated_pid)
      end
    end

  end


  class Haproxy < Base
    def initialize
      @config_erb_path = "/usr/local/etc/haproxy.cfg.erb"
      @config_path = "/usr/local/etc/haproxy.cfg"
      @pidfile_path = "/var/run/haproxy.pid"
      @exec = self.class.which('haproxy')
      @port = 5566
      @backends = []
    end

    def start
      compile_config
      self.class.fire_and_forget(@exec, 
        "-f #{@config_path}", 
        "> /var/log/haproxy.log 2>&1")
    end

    def soft_reload
      self.class.fire_and_forget(@exec, 
        "-f #{@config_path}",
        "-p #{@pidfile_path}",
        "-sf #{IO.read(@pidfile_path)}")
    end

    def kill
      self.class.kill(IO.read(@pidfile_path))
    end

    def add_tor(addr, port)
      @backends << {:name => 'tor', :addr => addr, :port => port}
    end

    private

    def compile_config
      IO.write(@config_path, ERB.new(IO.read(@config_erb_path)).result(binding))
    end
  end

end


h = Service::Haproxy.new

port = 10000
tor_instances = ENV['tors'] || 10
tor_instances.to_i.times.each do 
  t = Service::Tor.new(port)
  h.add_tor('127.0.0.1', t.delegated_port)
  t.start  
  port += 1
end

h.start



EM.run do
  # EM.add_periodic_timer(10) do
  #   # start another tor instance
  # end

  # ... 
  # @todo tor auto start and close depending on memory size and cpu usage
end

