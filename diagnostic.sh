#!/usr/bin/env bash
# Diagnostic de l'installation : versions, services, espace disque, licence, dernière sauvegarde. Aucune donnée sensible n'est affichée
# (ni mot de passe, ni clé, ni contenu de .env). Utile à joindre à une demande d'assistance.
cd "$(dirname "${BASH_SOURCE[0]}")"
echo "== ImmoGest — diagnostic du $(date -u +%FT%TZ)"
[ -f .env ] && { set -a; . ./.env; set +a; }
echo "Version installée : ${IMMOGEST_VERSION:-inconnue} | mode : ${CADDYFILE:-?} | site : ${IMMOGEST_SITE:-?} | profils : ${COMPOSE_PROFILES:-}"
echo "Docker : $(docker --version 2>&1) | $(docker compose version 2>&1)"
echo; echo "== Services"; docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}\t{{.Image}}' 2>&1
echo; echo "== Espace disque"; df -h . | sed -n '1,2p'
docker system df 2>/dev/null | sed -n '1,5p'
LIBRE_GO=$(df -Pk . | awk 'NR==2 {print int($4/1024/1024)}'); [ "$LIBRE_GO" -ge 5 ] || echo "ALERTE : moins de 5 Go libres"
echo; echo "== Licence"
docker compose exec -T sauvegarde psql -At -F ' | ' -c "SELECT 'importée le ' || to_char(created_at,'YYYY-MM-DD') FROM lic_licence ORDER BY created_at DESC LIMIT 1" 2>/dev/null || echo "(état indisponible : base arrêtée ?)"
echo "(détail : Paramètres > Licence, ou Paramètres > Sauvegardes > Diagnostic)"
echo; echo "== Sauvegardes"
docker compose exec -T sauvegarde sh -c 'ls -1d /sauvegardes/[0-9]*/ 2>/dev/null | sort | tail -n 5 | while read d; do echo "$(basename $d) : $(cat $d/MANIFEST.json 2>/dev/null | sed -n "s/.*\"externe\":\"\([^\"]*\)\".*/copie externe \1/p")"; done; ls /sauvegardes/cles 2>/dev/null | tail -n1 | sed "s/^/dernière clé sauvegardée : /"' 2>/dev/null || echo "(service de sauvegarde arrêté)"
docker compose exec -T sauvegarde cat /demandes/etat.json 2>/dev/null | sed 's/^/dernière opération : /'
