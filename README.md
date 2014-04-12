docker-rotating-proxies
=======================


```bash
# build docker container
docker build -t mattes/rotating-proxies:latest .

# debug docker container
docker run -v $(pwd):/home -p 5566:5566 -i -t mattes/rotating-proxies /bin/bash
source <(curl -Ls git.io/apeepg)

# start docker container
docker run -d -p 5566:5566 mattes/rotating-proxies

# test with ...
curl --proxy 127.0.0.1:5566 http://echoip.com
curl --proxy 127.0.0.1:5566 http://header.jsontest.com
```


