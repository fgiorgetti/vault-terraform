FROM alpine:3.19
RUN apk add --no-cache gnupg busybox
USER 10001
