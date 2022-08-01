FROM ubuntu:jammy
ARG CQLSH_VERSION=4.0.5
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		git python3-pip build-essential python3-dev && \
	git clone -b cassandra-${CQLSH_VERSION} --depth 1 https://github.com/apache/cassandra.git && \
	cd cassandra/pylib && pip install -U pip && pip install Cython && pip install --prefer-binary -r requirements.txt && pip install .
ENV PATH="/cassandra/bin:${PATH}"
WORKDIR /cassandra
