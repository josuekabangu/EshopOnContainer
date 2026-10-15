#!/usr/bin/env bash
# Démarre ou reconstruit le laboratoire, en une seule commande, sur un poste Linux.
#
# Enchaîne les étapes des sections 4 à 6 de lab-local/README.md : démarrage
# des machines par Vagrant, préparation des accès SSH et construction du
# cluster par Ansible, puis vérification des nœuds. Le playbook étant
# idempotent, le script peut être relancé sans risque sur un cluster existant.
#
# Sous Windows avec WSL2, utiliser lab-local/scripts/rebuild.ps1 : Vagrant doit
# y rester celui de Windows, et ce script refuse de s'exécuter dans WSL2.
#
# Usage :
#   bash lab-local/scripts/rebuild.sh              # démarrer ou relancer
#   bash lab-local/scripts/rebuild.sh --rebuild    # détruire puis reconstruire

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAGRANT_DIR="$PROJECT_ROOT/lab-local/vagrant"
ANSIBLE_DIR="$PROJECT_ROOT/lab-local/ansible"
PROVIDER=vmware_desktop
CONTROL_PLANE=192.168.57.10

REBUILD=false
case "${1:-}" in
    "") ;;
    --rebuild) REBUILD=true ;;
    *) echo "Usage : $0 [--rebuild]" >&2; exit 2 ;;
esac

step() { printf '\n=== %s\n' "$1"; }
fail() { echo "Erreur : $*" >&2; exit 1; }

START=$(date +%s)

# Prérequis vérifiés avant de toucher aux machines.
step "Vérification des prérequis"

# Dans WSL2, Vagrant doit rester celui de Windows : un Vagrant lancé depuis WSL2
# perdrait la trace des machines créées par l'autre (13-troubleshooting.md, problème 12).
if [[ -n "${WSL_DISTRO_NAME:-}" || -d /run/WSL ]]; then
    fail "WSL2 détecté. Utiliser lab-local/scripts/rebuild.ps1, depuis PowerShell."
fi

for cmd in vagrant ansible-playbook ssh; do
    command -v "$cmd" >/dev/null || fail "$cmd est introuvable."
done
vagrant plugin list | grep -q "vagrant-vmware-desktop" \
    || fail "le plugin vagrant-vmware-desktop n'est pas installé (vagrant plugin install vagrant-vmware-desktop)."
echo "Utilisateur : $(whoami)"
echo "Vagrant, Ansible, SSH et le plugin VMware sont présents."

cd "$VAGRANT_DIR"
if [[ "$REBUILD" == true ]]; then
    step "Destruction des machines"
    vagrant destroy -f
fi

step "Démarrage des machines"
vagrant up --provider "$PROVIDER"

step "Préparation des accès SSH"
bash "$PROJECT_ROOT/lab-local/scripts/setup-ssh.sh"

step "Construction du cluster"
cd "$ANSIBLE_DIR"
ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook site.yml

step "Vérification des nœuds"
ssh -i ~/.ssh/vagrant/kube-control "vagrant@$CONTROL_PLANE" kubectl get nodes -o wide

ELAPSED=$(( $(date +%s) - START ))
printf '\nLaboratoire prêt en %02d:%02d.\n' $((ELAPSED / 60)) $((ELAPSED % 60))
