docker-rotating-proxies
=======================

```
               Docker Container
               -----------------------
Client <---->  HAproxy <-> Tor Proxy 1
                           Tor Proxy 2
                           Tor Proxy n
```

__Why:__ Lots of IP addresses. One single endpoint for your client.
Load-balancing by HAproxy.


```bash
# build docker container
docker build -t mattes/rotating-proxies:latest .

# ... or pull docker container
docker pull mattes/rotating-proxies:latest

# debug docker container
docker run -v $(pwd):/home -p 5566:5566 -i -t mattes/rotating-proxies /bin/bash
source <(curl -Ls git.io/apeepg)

# start docker container
docker run -d -p 5566:5566 mattes/rotating-proxies

# test with ...
curl --proxy 127.0.0.1:5566 http://echoip.com
curl --proxy 127.0.0.1:5566 http://header.jsontest.com
```


Please note: Tor offers a SOCKS Proxy only. In order to allow communication
from HAproxy to Tor, [delegated](http://www.delegate.org/delegate/) 
is used to translate from HTTP proxy to SOCKS proxy.
HAproxy is able to talk to HTTP proxies only.

