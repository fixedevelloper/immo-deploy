#!/usr/bin/env bash
# Restaure une sauvegarde (base + fichiers) APPLICATION ARRÊTÉE.  ./restore.sh <identifiant> [--yes]
# Liste des sauvegardes : docker compose exec sauvegarde ls /sauvegardes   (ou Paramètres > Sauvegardes)
# Sauvegarde d'une AUTRE version : FORCER_VERSION=1 ./restore.sh <id>, après avoir remis l'image correspondante (IMMOGEST_VERSION dans .env).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ID="${1:-}"; [ -n "$ID" ] || { sed -n '2,4p' "$0"; exit 2; }
if [ "${2:-}" != "--yes" ]; then
  echo "Cette opération REMPLACE toutes les données actuelles par celles de la sauvegarde $ID."
  echo "(une sauvegarde « avant-restauration » est faite d'abord)"; read -r -p "Tapez RESTAURER pour continuer : " r; [ "$r" = RESTAURER ] || { echo "annulé"; exit 1; }
fi
# (restaurer.sh fait lui-même la sauvegarde « avant-restauration », application arrêtée)
docker compose stop app web
if docker compose exec -T -e FORCER_VERSION="${FORCER_VERSION:-0}" sauvegarde /opt/sauvegarde/restaurer.sh "$ID"; then
  docker compose up -d app web
  echo "Restauration terminée."
else
  echo "ÉCHEC de la restauration. L'application reste arrêtée : voir « docker compose logs sauvegarde »." >&2
  exit 1
fi
