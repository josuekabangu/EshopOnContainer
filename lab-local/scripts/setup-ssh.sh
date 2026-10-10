#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# PARAMÈTRES DU PROJET
# ==================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAGRANT_STATE="$PROJECT_ROOT/lab-local/vagrant/.vagrant/machines"
INVENTORY="$PROJECT_ROOT/lab-local/ansible/inventory.ini"

PROVIDER="vmware_desktop"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
WAIT_SECONDS=60

fail() {
    echo "ERREUR : $*" >&2
    exit 1
}

# Lit une variable d'une machine dans l'inventaire Ansible.
inventory_var() {
    local machine="$1" key="$2"
    awk -v m="$machine" -v k="$key" '
        $1 == m {
            for (i = 2; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == k) print pair[2]
            }
        }' "$INVENTORY" | tr -d '\r'
}

# Lit le chemin de la clé d'une machine et remplace un ~ initial par $HOME.
inventory_key() {
    local path
    path="$(inventory_var "$1" ansible_ssh_private_key_file)"
    printf '%s\n' "${path/#\~/$HOME}"
}

# ==================================================
# 1. VÉRIFIER LES PRÉREQUIS
# ==================================================

echo "=== 1. Vérification des prérequis ==="

for tool in ssh ssh-keygen ssh-keyscan awk install; do
    command -v "$tool" >/dev/null 2>&1 || fail "commande '$tool' introuvable."
done

[[ -f "$INVENTORY" ]] || fail "inventaire introuvable : $INVENTORY"

mapfile -t MACHINES < <(awk '/ansible_host=/ { print $1 }' "$INVENTORY" | tr -d '\r')

if [[ ${#MACHINES[@]} -eq 0 ]]; then
    fail "aucune machine trouvée dans $INVENTORY"
fi

echo "Machines de l'inventaire : ${MACHINES[*]}"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$KNOWN_HOSTS"

# ==================================================
# 2. COPIER LES CLÉS GÉNÉRÉES PAR VAGRANT
# ==================================================

echo
echo "=== 2. Copie des clés privées ==="

for machine in "${MACHINES[@]}"; do
    source_key="$VAGRANT_STATE/$machine/$PROVIDER/private_key"
    target_key="$(inventory_key "$machine")"

    [[ -n "$target_key" ]] || fail "ansible_ssh_private_key_file absent pour $machine."

    if [[ ! -f "$source_key" ]]; then
        fail "clé introuvable pour $machine : $source_key
Créer d'abord les machines dans PowerShell : vagrant up --provider $PROVIDER"
    fi

    mkdir -p "$(dirname "$target_key")"
    chmod 700 "$(dirname "$target_key")"
    install -m 600 "$source_key" "$target_key"

    echo "Clé copiée : $machine -> $target_key"
done

# ==================================================
# 3. ATTENDRE QUE LES MACHINES RÉPONDENT
# ==================================================

echo
echo "=== 3. Attente du service SSH ==="

for machine in "${MACHINES[@]}"; do
    ip="$(inventory_var "$machine" ansible_host)"
    elapsed=0

    until timeout 3 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null; do
        if (( elapsed >= WAIT_SECONDS )); then
            fail "$machine ($ip) ne répond pas sur le port 22 après ${WAIT_SECONDS}s.
Tester depuis PowerShell : Test-NetConnection $ip -Port 22
Voir docs/01-lab-local/13-troubleshooting.md, problèmes 4 et 13."
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done

    echo "Port 22 ouvert : $machine ($ip)"
done

# ==================================================
# 4. RENOUVELER LES EMPREINTES D'HÔTE
# ==================================================

echo
echo "=== 4. Renouvellement des empreintes ==="

for machine in "${MACHINES[@]}"; do
    ip="$(inventory_var "$machine" ansible_host)"

    ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    ssh-keyscan -H -T 5 "$ip" >> "$KNOWN_HOSTS" 2>/dev/null

    ssh-keygen -F "$ip" -f "$KNOWN_HOSTS" >/dev/null \
        || fail "empreinte de $machine ($ip) non enregistrée."

    echo "Empreinte enregistrée : $machine ($ip)"
done

# ==================================================
# 5. TESTER LES CONNEXIONS SSH
# ==================================================

echo
echo "=== 5. Vérification des connexions SSH ==="

for machine in "${MACHINES[@]}"; do
    ip="$(inventory_var "$machine" ansible_host)"
    user="$(inventory_var "$machine" ansible_user)"
    key="$(inventory_key "$machine")"

    remote_name="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$key" "$user@$ip" hostname)" \
        || fail "connexion SSH impossible à $machine ($ip)."

    [[ "$remote_name" == "$machine" ]] \
        || fail "$ip répond '$remote_name' au lieu de '$machine'."

    echo "Connexion SSH OK : $machine ($ip)"
done

# ==================================================
# 6. FIN
# ==================================================

echo
echo "=============================================="
echo "Accès SSH prêts pour : ${MACHINES[*]}"
echo "Étape suivante : ansible all -m ping"
echo "=============================================="
