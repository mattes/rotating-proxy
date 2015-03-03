NAME = mattes/rotating-proxy
VERSION = latest

.PHONY: all build test

all: build

build:
	docker build -t $(NAME):$(VERSION) .

test:
	docker run -v $(pwd):/home -p 5567:5566 -i -t --env tors=10 $(NAME):$(VERSION) /bin/bash

