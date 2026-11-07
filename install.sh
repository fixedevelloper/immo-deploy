#!/usr/bin/env bash
# Installation d'ImmoGest chez le client. Relançable sans risque : un deploy/.env existant n'est JAMAIS réécrit (la clé de chiffrement
# des pièces d'identité n'est pas régénérable : la perdre rend ces fichiers illisibles).
#
#   ./install.sh                         # assistant interactif
#   ./install.sh --mode domaine --site immo.exemple.cm --yes
#   ./install.sh --mode local   --site 192.168.1.20  --yes     # sans Internet
#   ./install.sh --mode tunnel  --site immo.exemple.cm --tunnel-token <jeton Cloudflare> --yes
#   Stockage externe : --stockage externe --s3-endpoint https://s3.eu-central-003.backblazeb2.com --s3-bucket immogest \
#                      --s3-access-key ... --s3-secret-key ... [--s3-region ...]
#                  --port-http N --port-https N (si 80 / 443 sont déjà utilisés ; sans ces options, l'assistant propose un autre port)
# Autres options : --version X --licence-serveur-url URL --cle-publique BASE64 --images-prebuilt (tirer les images au lieu de les construire)
#                  --registre PREFIXE (avec --images-prebuilt : préfixe des images publiées, défaut ghcr.io/fixedevelloper/immogest ; images publiques, aucune connexion requise)
#                  --images-chargees (images déjà dans Docker, ex. `docker load` d'une archive de release : ni pull ni construction)
#                  --pas-de-demarrage --yes (aucune question)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODE=""; SITE=""; STOCKAGE=""; S3_ENDPOINT=""; S3_BUCKET="immogest"; S3_REGION="us-east-1"; S3_ACCESS=""; S3_SECRET=""
HTTP_PORT=80; HTTPS_PORT=443; TUNNEL_TOKEN=""; VERSION="latest"; LICENCE_URL=""; CLE_PUBLIQUE=""; PREBUILT=0; REGISTRE="ghcr.io/fixedevelloper/immogest"; DEMARRER=1; YES=0; VERSION_FOURNIE=0; PORT_HTTP_FOURNI=0; PORT_HTTPS_FOURNI=0

erreur() { echo "ERREUR : $*" >&2; exit 1; }
info() { echo "==> $*"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --site) SITE="${2:-}"; shift 2 ;;
    --stockage) STOCKAGE="${2:-}"; shift 2 ;;
    --s3-endpoint) S3_ENDPOINT="${2:-}"; shift 2 ;;
    --s3-bucket) S3_BUCKET="${2:-}"; shift 2 ;;
    --s3-region) S3_REGION="${2:-}"; shift 2 ;;
    --s3-access-key) S3_ACCESS="${2:-}"; shift 2 ;;
    --s3-secret-key) S3_SECRET="${2:-}"; shift 2 ;;
    --port-http) HTTP_PORT="${2:-}"; PORT_HTTP_FOURNI=1; shift 2 ;;
    --port-https) HTTPS_PORT="${2:-}"; PORT_HTTPS_FOURNI=1; shift 2 ;;
    --tunnel-token) TUNNEL_TOKEN="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; VERSION_FOURNIE=1; shift 2 ;;
    --licence-serveur-url) LICENCE_URL="${2:-}"; shift 2 ;;
    --cle-publique) CLE_PUBLIQUE="${2:-}"; shift 2 ;;
    --registre) REGISTRE="${2:-}"; shift 2 ;;
    --images-prebuilt) PREBUILT=1; shift ;;
    --images-chargees) PREBUILT=2; shift ;;
    --pas-de-demarrage) DEMARRER=0; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) erreur "option inconnue : $1" ;;
  esac
done

# Sans les sources du dépôt (dossier deploy copié seul) il n'y a rien à construire : on installe les images publiées
if [ "$PREBUILT" = 0 ] && [ ! -f ../backend/pom.xml ]; then PREBUILT=1; info "Sources absentes : installation à partir des images publiées (${REGISTRE})"; fi

demander() { # demander VARIABLE "question" [défaut]
  local var="$1" question="$2" defaut="${3:-}" reponse=""
  [ -n "${!var}" ] && return 0
  if [ "$YES" = 1 ]; then
    [ -n "$defaut" ] || erreur "valeur manquante : $question (option en ligne de commande requise avec --yes)"
    printf -v "$var" '%s' "$defaut"; return 0
  fi
  read -r -p "$question${defaut:+ [$defaut]} : " reponse
  printf -v "$var" '%s' "${reponse:-$defaut}"
}

# ------------------------------------------------------------------ contrôles préalables
info "Contrôles préalables"
command -v docker >/dev/null 2>&1 || erreur "Docker n'est pas installé (https://docs.docker.com/engine/install/)."
docker info >/dev/null 2>&1 || erreur "Le démon Docker ne répond pas (service arrêté, ou utilisateur hors du groupe « docker »)."
docker compose version >/dev/null 2>&1 || erreur "Docker Compose v2 est requis (paquet « docker-compose-plugin »)."
command -v openssl >/dev/null 2>&1 || erreur "openssl est requis pour générer les secrets."
LIBRE_GO=$(df -Pk . | awk 'NR==2 {print int($4/1024/1024)}')
[ "$LIBRE_GO" -ge 10 ] || erreur "Espace disque insuffisant : ${LIBRE_GO} Go libres, 10 Go au moins requis."
if [ -r /proc/meminfo ]; then
  RAM_MO=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  [ "$RAM_MO" -ge 3500 ] || echo "AVERTISSEMENT : ${RAM_MO} Mo de mémoire ; 4 Go sont recommandés." >&2
fi
if [ -f .env ]; then
  info "deploy/.env existe déjà : les secrets sont conservés, la configuration n'est pas modifiée."
  EXISTANT=1
else
  EXISTANT=0
fi

# ------------------------------------------------------------------ configuration
if [ "$EXISTANT" = 0 ]; then
  if [ -z "$MODE" ]; then
    if [ "$YES" = 1 ]; then erreur "--mode est requis avec --yes"; fi
    echo "Mode d'accès : 1) domaine (HTTPS public)  2) réseau local (sans Internet)  3) tunnel Cloudflare"
    read -r -p "Votre choix [1] : " c; case "${c:-1}" in 1) MODE=domaine ;; 2) MODE=local ;; 3) MODE=tunnel ;; *) erreur "choix invalide" ;; esac
  fi
  case "$MODE" in domaine|local|tunnel) ;; *) erreur "--mode doit être domaine, local ou tunnel" ;; esac
  case "$MODE" in
    domaine) demander SITE "Nom de domaine (le DNS doit pointer vers ce serveur ; ports 80 et 443 ouverts)" ;;
    local) IP_DEFAUT=$(hostname -I 2>/dev/null | awk '{print $1}'); demander SITE "Adresse IP ou nom du serveur sur le réseau local" "$IP_DEFAUT" ;;
    tunnel) demander SITE "Nom de domaine public du tunnel Cloudflare"; demander TUNNEL_TOKEN "Jeton du tunnel Cloudflare" ;;
  esac
  [ -n "$SITE" ] || erreur "adresse du site manquante"
  [[ "$SITE" =~ ^[A-Za-z0-9._:-]+$ ]] || erreur "adresse du site invalide : $SITE"
  if [ -z "$STOCKAGE" ]; then
    if [ "$YES" = 1 ]; then STOCKAGE=local; else
      echo "Stockage des fichiers : 1) local (SeaweedFS, livré)  2) S3 externe (AWS, Backblaze B2, MinIO existant…)"
      read -r -p "Votre choix [1] : " c; case "${c:-1}" in 1) STOCKAGE=local ;; 2) STOCKAGE=externe ;; *) erreur "choix invalide" ;; esac
    fi
  fi
  case "$STOCKAGE" in local|externe) ;; *) erreur "--stockage doit être local ou externe" ;; esac
  if [ "$STOCKAGE" = externe ]; then
    [ "$MODE" != local ] || echo "AVERTISSEMENT : un stockage externe suppose un accès Internet, ce qui contredit le mode réseau local (sauf MinIO interne)." >&2
    demander S3_ENDPOINT "Adresse (endpoint) S3"; demander S3_ACCESS "Clé d'accès S3"; demander S3_SECRET "Clé secrète S3"
    [[ "$S3_ENDPOINT" =~ ^https?:// ]] || erreur "l'endpoint S3 doit commencer par http:// ou https://"
  fi
  [ "$MODE" = local ] || demander LICENCE_URL "Adresse du serveur de licences de l'éditeur (vide : pas de vérification en ligne)" "-"
  [ "$LICENCE_URL" != "-" ] || LICENCE_URL=""
  [ "$MODE" != local ] || LICENCE_URL=""   # sans Internet : licence vérifiée hors ligne uniquement

  # identifiant machine : lié à l'empreinte de la licence (CLAUDE.md §6, règle 8)
  MACHINE_ID=""
  [ -r /etc/machine-id ] && MACHINE_ID=$(tr -d '[:space:]' < /etc/machine-id)
  [ -n "$MACHINE_ID" ] || MACHINE_ID=$(openssl rand -hex 16)   # générée une fois, conservée dans .env
  [ -n "$MACHINE_ID" ] || erreur "identifiant machine introuvable"

  # ------------------------------------------------------------------ secrets
  info "Génération des secrets (deploy/.env, lisible par vous seul)"
  umask 077
  PROFILS=""; [ "$STOCKAGE" = local ] && PROFILS="stockage-local"
  [ "$MODE" = tunnel ] && PROFILS="${PROFILS:+$PROFILS,}tunnel"
  case "$MODE" in domaine) CADDYFILE=Caddyfile.domaine ;; local) CADDYFILE=Caddyfile.local ;; tunnel) CADDYFILE=Caddyfile.tunnel ;; esac
  if [ "$STOCKAGE" = local ]; then
    S3_ENDPOINT="http://seaweedfs:8333"; S3_ACCESS="immogest-$(openssl rand -hex 6)"; S3_SECRET=$(openssl rand -hex 24)
    mkdir -p generated
    cat > generated/s3.json <<JSON
{
  "identities": [
    {
      "name": "immogest",
      "credentials": [{ "accessKey": "$S3_ACCESS", "secretKey": "$S3_SECRET" }],
      "actions": ["Admin", "Read", "List", "Tagging", "Write"]
    }
  ]
}
JSON
    # Lu par le processus du conteneur SeaweedFS, dont l'uid n'est pas celui de l'installateur : en 0600 il est refusé (« permission denied »,
    # l'API ne démarre jamais faute de stockage). Le dossier generated/ reste en 0700 : les autres utilisateurs de la machine n'y accèdent pas.
    chmod 0644 generated/s3.json
  fi
  mkdir -p generated/sans-disque-externe
  # Images publiées : leurs noms sont mémorisés dans .env pour que docker compose et update.sh --registre tirent les mêmes
  IMAGES_ENV=""
  if [ "$PREBUILT" = 1 ]; then
    [[ "$REGISTRE" =~ ^[a-z0-9./:_-]+$ ]] || erreur "préfixe d'images invalide : $REGISTRE"
    IMAGES_ENV="IMMOGEST_IMAGE_APP=${IMMOGEST_IMAGE_APP:-$REGISTRE-app}
IMMOGEST_IMAGE_WEB=${IMMOGEST_IMAGE_WEB:-$REGISTRE-web}
IMMOGEST_IMAGE_SAUVEGARDE=${IMMOGEST_IMAGE_SAUVEGARDE:-$REGISTRE-sauvegarde}"
  fi
  cat > .env <<ENV
# Généré par install.sh le $(date -u +%FT%TZ). NE PAS COMMITER. Sauvegardez ce fichier hors du serveur (surtout IMMOGEST_CLE_CHIFFREMENT).
COMPOSE_PROFILES=$PROFILS
CADDYFILE=$CADDYFILE
IMMOGEST_SITE=$SITE
IMMOGEST_HTTP_PORT=$HTTP_PORT
IMMOGEST_HTTPS_PORT=$HTTPS_PORT
IMMOGEST_VERSION=$VERSION
$IMAGES_ENV
POSTGRES_PASSWORD=$(openssl rand -hex 24)
IMMOGEST_JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
IMMOGEST_CLE_CHIFFREMENT=$(openssl rand -base64 32 | tr -d '\n')
IMMOGEST_S3_ENDPOINT=$S3_ENDPOINT
IMMOGEST_S3_REGION=$S3_REGION
IMMOGEST_S3_BUCKET=$S3_BUCKET
IMMOGEST_S3_ACCESS_KEY=$S3_ACCESS
IMMOGEST_S3_SECRET_KEY=$S3_SECRET
IMMOGEST_MACHINE_ID=$MACHINE_ID
IMMOGEST_LICENCE_SERVEUR_URL=$LICENCE_URL
IMMOGEST_LICENCE_CLE_PUBLIQUE=$CLE_PUBLIQUE
IMMOGEST_RESEAU_LOCAL=$([ "$MODE" = local ] && echo true || echo false)
SAUVEGARDE_PASSPHRASE=$(openssl rand -base64 24 | tr -d '\n')
SAUVEGARDE_HEURE=02:30
SAUVEGARDE_RETENTION_JOURS=30
# Copie externe des sauvegardes (voir deploy/README.md) : un autre S3, ou un dossier de l'hôte (disque USB, NAS monté)
SAUVEGARDE_DISQUE_EXTERNE=
SAUVEGARDE_EXTERNE_S3_ENDPOINT=
SAUVEGARDE_EXTERNE_S3_BUCKET=
SAUVEGARDE_EXTERNE_S3_PREFIXE=immogest
SAUVEGARDE_EXTERNE_S3_ACCESS_KEY=
SAUVEGARDE_EXTERNE_S3_SECRET_KEY=
SAUVEGARDE_EXTERNE_S3_REGION=us-east-1
CLOUDFLARE_TUNNEL_TOKEN=$TUNNEL_TOKEN
ENV
  chmod 600 .env
fi

# ------------------------------------------------------------------ ports (hors tunnel)
# .env existant : il n'est pas réécrit, mais les ports demandés en ligne de commande y sont appliqués (aucun secret touché)
# Idem pour la version et les noms d'images (installation déjà faite sans --images-prebuilt, ou version à changer)
ecrire_env() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
[ "$VERSION_FOURNIE" != 1 ] || ecrire_env IMMOGEST_VERSION "$VERSION"
if [ "$PREBUILT" = 1 ] && ! grep -q '^IMMOGEST_IMAGE_APP=' .env; then
  ecrire_env IMMOGEST_IMAGE_APP "${IMMOGEST_IMAGE_APP:-$REGISTRE-app}"
  ecrire_env IMMOGEST_IMAGE_WEB "${IMMOGEST_IMAGE_WEB:-$REGISTRE-web}"
  ecrire_env IMMOGEST_IMAGE_SAUVEGARDE "${IMMOGEST_IMAGE_SAUVEGARDE:-$REGISTRE-sauvegarde}"
fi
for pair in "IMMOGEST_HTTP_PORT=$HTTP_PORT=$PORT_HTTP_FOURNI" "IMMOGEST_HTTPS_PORT=$HTTPS_PORT=$PORT_HTTPS_FOURNI"; do
  IFS== read -r var val fourni <<< "$pair"
  [ "$fourni" = 1 ] || continue
  [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 65535 ] || erreur "port invalide : $val"
  if grep -q "^$var=" .env; then sed -i "s/^$var=.*/$var=$val/" .env; else printf '%s=%s\n' "$var" "$val" >> .env; fi
done
set -a; . ./.env; set +a
if [ "$DEMARRER" = 1 ] && [ "${CADDYFILE:-}" != Caddyfile.tunnel ] && command -v ss >/dev/null 2>&1; then
  if ! docker compose ps --status running --services 2>/dev/null | grep -qx caddy; then
    port_occupe() { ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q LISTEN; }
    for var in IMMOGEST_HTTP_PORT IMMOGEST_HTTPS_PORT; do
      p="${!var:-}"; [ -n "$p" ] || { [ "$var" = IMMOGEST_HTTP_PORT ] && p=80 || p=443; }
      port_occupe "$p" || continue
      suggestion=$([ "$var" = IMMOGEST_HTTP_PORT ] && echo 8080 || echo 8443)
      while port_occupe "$suggestion"; do suggestion=$((suggestion + 1)); done
      [ "$YES" != 1 ] || erreur "le port $p est déjà utilisé sur ce serveur (autre serveur web ?). Relancez avec --port-http N --port-https N (ex. $suggestion), ou libérez le port."
      echo "Le port $p est déjà utilisé sur ce serveur (autre serveur web ?)."
      while :; do
        read -r -p "Port à utiliser pour ImmoGest [$suggestion] : " nouveau; nouveau="${nouveau:-$suggestion}"
        [[ "$nouveau" =~ ^[0-9]+$ ]] && [ "$nouveau" -ge 1 ] && [ "$nouveau" -le 65535 ] || { echo "  port invalide"; continue; }
        port_occupe "$nouveau" && { echo "  le port $nouveau est lui aussi utilisé"; continue; }
        [ "$nouveau" != "${IMMOGEST_HTTP_PORT:-80}" ] || [ "$var" = IMMOGEST_HTTP_PORT ] || { echo "  ce port est déjà celui du HTTP"; continue; }
        break
      done
      sed -i "s/^$var=.*/$var=$nouveau/" .env
      printf -v "$var" '%s' "$nouveau"
      if [ "${CADDYFILE:-}" = Caddyfile.domaine ]; then
        echo "  Attention : en mode « domaine », Let's Encrypt a besoin que Internet atteigne le port 80 (ou 443) de ce serveur ; avec un autre port, placez un reverse proxy devant ou utilisez --mode tunnel."
      fi
    done
  fi
fi

# ------------------------------------------------------------------ démarrage
if [ "$DEMARRER" = 0 ]; then info "Configuration écrite. Démarrage : cd deploy && docker compose up -d --build"; exit 0; fi
if [ "$PREBUILT" = 2 ]; then
  info "Images déjà chargées : aucune construction ni téléchargement"
  docker compose up -d --no-build
elif [ "$PREBUILT" = 1 ]; then
  info "Téléchargement des images"; docker compose pull app web sauvegarde
  docker compose up -d --no-build   # jamais de construction locale : on installe exactement les images publiées
else
  [ -f ../backend/pom.xml ] || erreur "sources absentes : utilisez --images-prebuilt avec IMMOGEST_IMAGE_APP / IMMOGEST_IMAGE_WEB"
  info "Construction des images (plusieurs minutes la première fois)"
  docker compose up -d --build
fi

info "Attente du démarrage de l'application (migrations comprises)"
for _ in $(seq 1 90); do
  etat=$(docker compose ps app --format '{{.Health}}' 2>/dev/null || true)
  [ "$etat" = healthy ] && break
  sleep 5
done
[ "${etat:-}" = healthy ] || { docker compose logs --tail 40 app >&2; erreur "l'application ne répond pas. Journal : docker compose logs app"; }

URL="https://$IMMOGEST_SITE"
if [ "${CADDYFILE:-}" != Caddyfile.tunnel ] && [ "${IMMOGEST_HTTPS_PORT:-443}" != 443 ]; then URL="$URL:${IMMOGEST_HTTPS_PORT}"; fi
echo
echo "ImmoGest est démarré : $URL"
echo "  1. Ouvrez cette adresse : l'assistant crée le compte administrateur et importe votre licence."
echo "  2. Dans l'application mobile, saisissez l'adresse ci-dessus (ou scannez ce code) :"
if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 "$URL"; else echo "     (installez « qrencode » pour afficher le code QR ici)"; fi
case "${CADDYFILE:-}" in
  Caddyfile.local) echo "  Note : certificat local — installez le certificat racine de Caddy sur les postes, sinon le navigateur affichera un avertissement." ;;
  Caddyfile.domaine) echo "  Note : le certificat HTTPS est obtenu au premier accès (quelques secondes)." ;;
esac
echo "  Sauvegardes : quotidiennes à 02:30 (Paramètres > Sauvegardes). Configurez une COPIE EXTERNE (disque ou autre S3) : voir deploy/README.md."
echo "  IMPORTANT : copiez deploy/.env hors du serveur. Sans IMMOGEST_CLE_CHIFFREMENT, les pièces d'identité chiffrées sont irrécupérables."
