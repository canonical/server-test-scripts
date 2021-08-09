FROM ubuntu:impish
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		git python3-pip build-essential python3-dev && \
	git clone https://github.com/apache/cassandra.git && \
	cd cassandra/pylib && pip install Cython && pip install -r requirements.txt && pip install .
ENV PATH="/cassandra/bin:${PATH}"
WORKDIR /cassandra
