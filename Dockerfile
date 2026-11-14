FROM postgres:18

ARG HTTP_PROXY
ARG HTTPS_PROXY

ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}

# vim-tiny fournit "vi" : nécessaire à "patronictl edit-config"
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip gcc python3-dev vim-tiny && \
    pip3 install --break-system-packages \
      "patroni[etcd3]" \
      "psycopg[binary]" && \
    rm -rf /var/lib/apt/lists/*

ENV EDITOR=vi

USER postgres

CMD ["patroni","/etc/patroni/patroni.yml"]
