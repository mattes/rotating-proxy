include .env
export


# Operating with simple Docker container
# --------------------------------------

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


# Operating with Docker service
# -----------------------------

service:
	docker service create -p ${TOR_ENTRY_PORT}:5566 -p ${HAPROXY_PORT}:4444 --env tors=${TOR_INSTANCES} --name ${SERVICE_NAME} ${IMAGE_NAME}

service-ls:
	docker service ls | grep "${SERVICE_NAME}"

service-log:
	docker service logs ${SERVICE_NAME}

service-flog:
	docker service logs --follow ${SERVICE_NAME}

service-rm:
	docker service rm ${SERVICE_NAME}
