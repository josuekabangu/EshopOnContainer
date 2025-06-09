#!/bin/bash
set -e

echo "[INIT-JENKINS] Installation de Docker et K3s dans le conteneur Jenkins..."

# Installer Docker
echo "[Docker] Installation de Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# Créer groupe docker si absent, ajouter jenkins
if ! getent group docker >/dev/null; then
  groupadd docker
fi
usermod -aG docker jenkins

echo "Docker installé et utilisateur jenkins ajouté au groupe docker."

# Installer K3s (version minimale Kubernetes)
echo "[K3s] Installation de K3s..."
curl -sfL https://get.k3s.io | sh -

# Configurer KUBECONFIG pour utilisateur jenkins
mkdir -p /var/jenkins_home/.kube
cp /etc/rancher/k3s/k3s.yaml /var/jenkins_home/.kube/config
chown -R jenkins:jenkins /var/jenkins_home/.kube

# Ajouter la variable d'environnement KUBECONFIG dans le profil jenkins
echo 'export KUBECONFIG=$HOME/.kube/config' >> /var/jenkins_home/.bashrc

echo "K3s installé et configuré."

# Lancer Jenkins en mode normal (avec exec pour remplacer le shell)
exec /sbin/tini -- /usr/local/bin/jenkins.sh
