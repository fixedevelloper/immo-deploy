#!/usr/bin/env bash
# Sauvegarde immédiate (base + fichiers + clé chiffrée + copie externe si configurée).  ./backup.sh [étiquette]
# La sauvegarde quotidienne (02:30) est faite par le conteneur « sauvegarde » ; ce script la déclenche à la main.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
docker compose ps --status running --services | grep -qx sauvegarde || { echo "ERREUR : le service de sauvegarde ne tourne pas (docker compose up -d sauvegarde)" >&2; exit 1; }
docker compose exec -T sauvegarde /opt/sauvegarde/sauvegarder.sh "$@"
