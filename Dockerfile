FROM registry.redhat.io/ubi9/ubi-minimal:latest
RUN microdnf install -y --nodocs --setopt=install_weak_deps=0 gnupg2 jq wget gawk hostname \
    && microdnf clean all
USER 10001
