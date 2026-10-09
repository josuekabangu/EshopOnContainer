
#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# PARAMÈTRES DU PROJET
# ==================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAGRANT_DIR="$PROJECT_ROOT/lab-local/vagrant"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/eshop-vagrant-config"

MACHINES=(
    "kube-control"
    "kube-worker"
)

# ==================================================
# 1. VÉRIFIER LES PRÉREQUIS
# ==================================================

echo "=== 1. Vérification des prérequis ==="

for command in vagrant ssh; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERREUR : commande '$command' introuvable." >&2
        exit 1
    fi
done

if [[ ! -f "$VAGRANT_DIR/Vagrantfile" ]]; then
    echo "ERREUR : Vagrantfile introuvable : $VAGRANT_DIR" >&2
    exit 1
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ==================================================
# 2. DÉMARRER LES MACHINES
# ==================================================

echo
echo "=== 2. Démarrage des machines virtuelles ==="

cd "$VAGRANT_DIR"
vagrant up

# ==================================================
# 3. VÉRIFIER L'ÉTAT DES MACHINES
# ==================================================

echo
echo "=== 3. Vérification de l'état des machines ==="

vagrant status

# ==================================================
# 4. GÉNÉRER LA CONFIGURATION SSH
# ==================================================

echo
echo "=== 4. Génération de la configuration SSH ==="

TEMP_CONFIG="$(mktemp "$SSH_DIR/eshop-vagrant-config.XXXXXX")"

cleanup() {
    rm -f "$TEMP_CONFIG"
}

trap cleanup EXIT

{
    echo "# Configuration générée automatiquement par EshopOnContainer"
    echo

    for machine in "${MACHINES[@]}"; do
        echo "# Configuration de $machine"
        vagrant ssh-config "$machine"
        echo
    done
} > "$TEMP_CONFIG"

chmod 600 "$TEMP_CONFIG"
mv "$TEMP_CONFIG" "$SSH_CONFIG"
trap - EXIT

echo "Configuration enregistrée : $SSH_CONFIG"

# ==================================================
# 5. TESTER LES CONNEXIONS SSH
# ==================================================

echo
echo "=== 5. Vérification des connexions SSH ==="

for machine in "${MACHINES[@]}"; do
    echo
    echo "Connexion à $machine..."

    if ssh \
        -F "$SSH_CONFIG" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "$machine" \
        'hostname'; then
        echo "Connexion SSH OK : $machine"
    else
        echo "ERREUR : connexion SSH impossible à $machine." >&2
        exit 1
    fi
done

# ==================================================
# 6. FIN
# ==================================================

echo
echo "=============================================="
echo "Laboratoire EshopOnContainer prêt."
echo "Configuration SSH : $SSH_CONFIG"
echo "=============================================="
