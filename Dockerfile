FROM ubuntu:12.04
MAINTAINER Matthias Kadenbach <matthias.kadenbach@gmail.com>

RUN apt-get update
# RUN apt-get upgrade -y
RUN apt-get install libssl-dev wget curl ruby1.9.3 -y
RUN ln -s /lib/x86_64-linux-gnu/libssl.so.1.0.0 /lib/libssl.so.1.0.0

# Tor
RUN echo 'deb http://deb.torproject.org/torproject.org precise main' | tee /etc/apt/sources.list.d/torproject.list
RUN gpg --keyserver keys.gnupg.net --recv 886DDD89
RUN gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -
RUN apt-get update
RUN apt-get install tor -y
RUN service tor stop
RUN update-rc.d -f tor remove

# Polipo
RUN apt-get install polipo -y
RUN update-rc.d -f polipo remove

# HAproxy
RUN apt-get install haproxy -y

EXPOSE 5566

ADD usr/local/etc/haproxy.cfg.erb /usr/local/etc/haproxy.cfg.erb

ADD usr/local/bin/start.rb /usr/local/bin/start.rb
RUN chmod +x /usr/local/bin/start.rb
RUN apt-get install build-essential -y
RUN gem install eventmachine

CMD /usr/local/bin/start.rb