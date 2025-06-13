#!/bin/bash
set -e

echo "[INIT-JENKINS] Installation de K3s dans le conteneur Jenkins..."

# Vérifier si Docker est accessible via DOCKER_HOST
if ! docker info > /dev/null 2>&1; then
  echo "Docker non accessible depuis le conteneur Jenkins."
  exit 1
fi
echo "Docker est accessible."

# Installer K3s binaire (version définie)
K3S_VERSION="v1.32.5+k3s1"
if ! command -v k3s >/dev/null 2>&1; then
  echo "[K3s] Téléchargement et installation..."
  curl -Lo /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s
  chmod +x /usr/local/bin/k3s
else
  echo "K3s déjà installé."
fi

# Lancer k3s en mode server en arrière-plan (désactiver traefik, servicelb, metrics-server)
echo "Démarrage de k3s server..."
/usr/local/bin/k3s server --no-deploy=traefik,servicelb,metrics-server &
K3S_PID=$!

# Attendre que k3s soit prêt (test de l'API K8s)
echo "Attente que K3s soit prêt..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in {1..30}; do
  if k3s kubectl get nodes >/dev/null 2>&1; then
    echo "K3s prêt."
    break
  else
    echo "En attente de K3s... ($i/30)"
    sleep 2
  fi
done

if ! k3s kubectl get nodes >/dev/null 2>&1; then
  echo "Erreur : K3s n'a pas démarré correctement."
  exit 1
fi

# Copier kubeconfig dans le home jenkins
mkdir -p /var/jenkins_home/.kube
cp /etc/rancher/k3s/k3s.yaml /var/jenkins_home/.kube/config
chown -R jenkins:jenkins /var/jenkins_home/.kube

echo "K3s installé et kubeconfig copié."

# Garder le processus k3s en avant-plan pour que le conteneur reste actif
wait $K3S_PID
