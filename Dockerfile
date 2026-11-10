FROM alpine:3.19
RUN apk add --no-cache gnupg busybox curl jq
USER 10001
