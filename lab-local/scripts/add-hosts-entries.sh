#!/usr/bin/env bash
# Ajoute (ou retire) les noms du point d'entrée du laboratoire dans /etc/hosts.
#
# Le navigateur et les pods doivent joindre les services d'eShop par les mêmes
# noms, en .eshop.lab. Les pods les obtiennent de CoreDNS (rôle Ansible lab_dns) ;
# ce script les apprend au poste, en les faisant pointer vers l'adresse du
# point d'entrée, attribuée par MetalLB. Il peut être relancé sans risque.
#
# --remove ne retire que la ligne ajoutée par ce script, reconnue à sa
# marque "# EshopOnContainer lab", et garde une copie du fichier d'origine.
#
# La liste des noms doit rester identique à lab_dns_names
# (lab-local/ansible/group_vars/control_plane.yml).
#
# Usage :
#   sudo bash lab-local/scripts/add-hosts-entries.sh
#   sudo bash lab-local/scripts/add-hosts-entries.sh --remove

set -euo pipefail

HOSTS_FILE=/etc/hosts
NAMES=(shop.eshop.lab identity.eshop.lab webhooks.eshop.lab)
ADDRESS=192.168.57.20
MARKER="# EshopOnContainer lab"
ENTRY="${ADDRESS}	${NAMES[*]}	${MARKER}"

# Lignes ajoutées par ce script
OURS_PATTERN="#[[:space:]]*EshopOnContainer lab[[:space:]]*$"

if [[ $EUID -ne 0 ]]; then
    echo "Erreur : ce script modifie ${HOSTS_FILE} et doit être lancé avec sudo." >&2
    exit 1
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Erreur : WSL2 détecté. ${HOSTS_FILE} y est régénéré depuis Windows à chaque démarrage." >&2
    echo "Utiliser lab-local/scripts/add-hosts-entries.ps1, dans PowerShell en administrateur." >&2
    exit 1
fi

if [[ "${1:-}" == "--remove" ]]; then
    if ! grep -Eq "$OURS_PATTERN" "$HOSTS_FILE"; then
        echo "Aucune ligne ajoutée par ce script : rien à retirer."
        exit 0
    fi
    cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"
    grep -Ev "$OURS_PATTERN" "${HOSTS_FILE}.bak" > "$HOSTS_FILE"
    echo "Ligne ajoutée par ce script retirée. Copie de l'original : ${HOSTS_FILE}.bak"
    exit 0
fi

OURS=$(grep -E "$OURS_PATTERN" "$HOSTS_FILE" || true)
if [[ -n "$OURS" ]]; then
    if [[ "$OURS" == "$ENTRY" ]]; then
        echo "Déjà présent : ${ENTRY}"
        exit 0
    fi
    echo "Erreur : une ligne de ce script existe, mais diffère : ${OURS}" >&2
    echo "Lancer d'abord le script avec --remove." >&2
    exit 1
fi

# Un nom déclaré ailleurs, à la main ou par un autre outil, entrerait en conflit
for NAME in "${NAMES[@]}"; do
    PATTERN="^[[:space:]]*[^#[:space:]]+[[:space:]]+(.*[[:space:]])?${NAME//./\\.}([[:space:]]|#|$)"
    OTHER=$(grep -E "$PATTERN" "$HOSTS_FILE" || true)
    if [[ -n "$OTHER" ]]; then
        echo "Erreur : '${NAME}' est déjà déclaré : ${OTHER}" >&2
        echo "Corriger la ligne à la main." >&2
        exit 1
    fi
done

# Ajouter un saut de ligne si le fichier ne se termine pas par un
if [[ -s "$HOSTS_FILE" && -n "$(tail -c 1 "$HOSTS_FILE")" ]]; then
    echo >> "$HOSTS_FILE"
fi
echo "$ENTRY" >> "$HOSTS_FILE"
echo "Ajouté : ${ENTRY}"

# Vérification : le système résout-il chaque nom ?
for NAME in "${NAMES[@]}"; do
    if getent hosts "$NAME" | grep -q "^${ADDRESS//./\\.}[[:space:]]"; then
        echo "Vérifié : ${NAME} -> ${ADDRESS}"
    else
        echo "Attention : '${NAME}' n'est pas encore résolu vers ${ADDRESS}." >&2
    fi
done
