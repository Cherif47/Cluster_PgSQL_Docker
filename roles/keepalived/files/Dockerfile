FROM alpine:3.20
RUN apk add --no-cache keepalived bash
ENTRYPOINT ["keepalived", "-n", "-l", "-D", "-f", "/etc/keepalived/keepalived.conf"]
