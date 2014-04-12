FROM ubuntu:12.04
MAINTAINER Matthias Kadenbach <matthias.kadenbach@gmail.com>

RUN apt-get update
# RUN apt-get upgrade -y
RUN apt-get install wget -y

# Tor
RUN echo 'deb http://deb.torproject.org/torproject.org precise main' | tee /etc/apt/sources.list.d/torproject.list
RUN gpg --keyserver keys.gnupg.net --recv 886DDD89
RUN gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | sudo apt-key add -
RUN apt-get update
RUN apt-get install tor -y
RUN service tor stop
RUN update-rc.d -f tor remove

# DeleGate
RUN wget -P /tmp http://www.delegate.org/anonftp/DeleGate/bin/linux/9.9.7/fc6_64-dg.gz
RUN gunzip /tmp/fc6_64-dg.gz
RUN mv /tmp/fc6_64-dg /usr/bin/delegated
RUN chmod +x /usr/bin/delegated

# HAproxy
RUN apt-get install haproxy -y