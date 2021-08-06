FROM ubuntu:devel

RUN set -eux; \
	apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y; \
	DEBIAN_FRONTEND=noninteractive apt-get install shunit2 curl moreutils netcat-openbsd -y; \
	rm -rf /var/lib/apt/lists/*

WORKDIR /tests
COPY . .

ENTRYPOINT [ "/tests/tests.sh" ]
