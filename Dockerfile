FROM ubuntu:14.04
MAINTAINER Matthias Kadenbach <matthias.kadenbach@gmail.com>

RUN apt-get update
RUN apt-get upgrade -y
RUN apt-get install libssl-dev wget curl -y
RUN apt-get install build-essential zlib1g-dev libyaml-dev libssl-dev libgdbm-dev libreadline-dev libncurses5-dev libffi-dev
RUN ln -s /lib/x86_64-linux-gnu/libssl.so.1.0.0 /lib/libssl.so.1.0.0

# Tor
RUN echo 'deb http://deb.torproject.org/torproject.org trusty main' | tee /etc/apt/sources.list.d/torproject.list
RUN gpg --keyserver keys.gnupg.net --recv 886DDD89
RUN gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -

# Ruby
RUN echo 'deb http://ppa.launchpad.net/brightbox/ruby-ng/ubuntu trusty main' | tee /etc/apt/sources.list.d/ruby.list
RUN gpg --keyserver keyserver.ubuntu.com --recv C3173AA6
RUN gpg --export 80f70e11f0f0d5f10cb20e62f5da5f09c3173aa6 | apt-key add -

# Services
RUN apt-get update
RUN apt-get install tor polipo haproxy ruby2.1 -y

RUN service tor stop
RUN service polipo stop
RUN update-rc.d -f tor remove
RUN update-rc.d -f polipo remove

EXPOSE 5566

RUN gem install excon

ADD usr/local/etc/haproxy.cfg.erb /usr/local/etc/haproxy.cfg.erb
ADD usr/local/bin/start.rb /usr/local/bin/start.rb
RUN chmod +x /usr/local/bin/start.rb
CMD /usr/local/bin/start.rb
