NAME = mattes/rotating-proxy
VERSION = latest

.PHONY: all build test pull

all: pull build

build:
	docker build -t $(NAME):$(VERSION) .

test:
	docker run --rm -p 5567:5566 -i -t --env tors=10 $(NAME):$(VERSION) /bin/bash

pull:
	git pull origin master

run:
	docker run -d -p 5566:5566 --env tors=10 --env test_url="http://www.check24.de/" --name tor $(NAME):$(VERSION)
