include .env
export

run:
	docker run -d -p ${TOR_ENTRY_PORT}:5566 -p ${HAPROXY_PORT}:4444 --env tors=${TOR_INSTANCES} --name ${CONTAINER_NAME} ${IMAGE_NAME}

ps:
	docker ps -a | grep "${CONTAINER_NAME}"

log:
	docker logs ${CONTAINER_NAME}

flog:
	docker logs --follow ${CONTAINER_NAME}

stop:
	docker stop ${CONTAINER_NAME}

rm:
	docker rm ${CONTAINER_NAME}

remove:
	make stop
	make rm
