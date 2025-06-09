FROM jenkins/jenkins:lts

USER root

# Installer les dépendances nécessaires pour Docker + K3s
RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    bash \
    sudo

# Copier le script d'installation
COPY scripts/init-jenkins.sh /usr/local/bin/init-jenkins.sh
RUN chmod +x /usr/local/bin/init-jenkins.sh

USER jenkins
