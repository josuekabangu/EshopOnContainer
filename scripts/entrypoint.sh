#!/bin/bash
set -e

# Lancer le script d'initialisation en arrière-plan
/usr/local/bin/init-jenkins.sh &

# Lancer Jenkins avec tini au bon chemin
exec /usr/bin/tini -- /usr/local/bin/jenkins.sh "$@"
