#!/usr/bin/env bash
# Ajoute (ou retire) le nom identity-api dans /etc/hosts.
#
# Le navigateur et les conteneurs doivent joindre Identity.API par la même
# adresse, http://identity-api:5223. Les conteneurs connaissent ce nom par le
# réseau Docker ; ce script l'apprend au poste en le faisant pointer vers
# 127.0.0.1. Il peut être relancé sans risque : il ne fait rien si le nom
# est déjà déclaré vers cette adresse.
#
# --remove ne retire que la ligne ajoutée par ce script, reconnue à sa
# marque "# EshopOnContainer", et garde une copie du fichier d'origine.
#
# Usage :
#   sudo bash docker/scripts/linux/add-hosts-entry.sh
#   sudo bash docker/scripts/linux/add-hosts-entry.sh --remove

set -euo pipefail

HOSTS_FILE=/etc/hosts
NAME=identity-api
ADDRESS=127.0.0.1
MARKER="# EshopOnContainer"
ENTRY="${ADDRESS}	${NAME}	${MARKER}"

# Lignes actives (non commentées) qui déclarent ce nom
PATTERN="^[[:space:]]*[^#[:space:]]+[[:space:]]+(.*[[:space:]])?${NAME}([[:space:]]|#|$)"
# Parmi elles, celles qu'a ajoutées ce script
OURS_PATTERN="${PATTERN}.*#[[:space:]]*EshopOnContainer[[:space:]]*$"

if [[ $EUID -ne 0 ]]; then
    echo "Erreur : ce script modifie ${HOSTS_FILE} et doit être lancé avec sudo." >&2
    exit 1
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Erreur : WSL2 détecté. ${HOSTS_FILE} y est régénéré depuis Windows à chaque démarrage." >&2
    echo "Utiliser docker/scripts/windows/add-hosts-entry.ps1, dans PowerShell en administrateur." >&2
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

EXISTING=$(grep -E "$PATTERN" "$HOSTS_FILE" || true)
if [[ -n "$EXISTING" ]]; then
    if grep -Eq "^[[:space:]]*${ADDRESS//./\\.}[[:space:]]" <<< "$EXISTING"; then
        echo "Déjà présent : ${EXISTING}"
        exit 0
    fi
    echo "Erreur : '${NAME}' est déjà déclaré avec une autre adresse : ${EXISTING}" >&2
    echo "Corriger la ligne à la main." >&2
    exit 1
fi

# Ajouter un saut de ligne si le fichier ne se termine pas par un
if [[ -s "$HOSTS_FILE" && -n "$(tail -c 1 "$HOSTS_FILE")" ]]; then
    echo >> "$HOSTS_FILE"
fi
echo "$ENTRY" >> "$HOSTS_FILE"
echo "Ajouté : ${ENTRY}"

# Vérification : le système résout-il le nom ?
if getent hosts "$NAME" | grep -q "^${ADDRESS//./\\.}[[:space:]]"; then
    echo "Vérifié : ${NAME} -> ${ADDRESS}"
else
    echo "Attention : '${NAME}' n'est pas encore résolu vers ${ADDRESS}." >&2
fi
