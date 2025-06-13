FROM jenkins/jenkins:lts

USER root

RUN apt-get update && apt-get install -y \
    curl \
    bash \
    sudo \
    iproute2 \
    socat \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/init-jenkins.sh /usr/local/bin/init-jenkins.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-jenkins.sh /usr/local/bin/entrypoint.sh

USER jenkins

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
