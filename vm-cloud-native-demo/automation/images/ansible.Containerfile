# Example image; pin base digest and validate dependency support for your environment.
FROM registry.access.redhat.com/ubi9/ubi:latest
RUN dnf -y install python3 python3-pip openssh-clients && \
    python3 -m pip install --no-cache-dir ansible-core==2.16.14 && \
    dnf clean all
