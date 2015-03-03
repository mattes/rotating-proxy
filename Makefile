NAME = mattes/rotating-proxy
VERSION = latest

.PHONY: all build test pull

all: pull build

build:
	docker build -t $(NAME):$(VERSION) .

test:
	docker run -p 5567:5566 -i -t --env tors=10 $(NAME):$(VERSION) /bin/bash

pull:
	git pull origin master

