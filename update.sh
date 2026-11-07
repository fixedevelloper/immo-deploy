#!/usr/bin/env bash
# Mise à jour d'ImmoGest : télécharge → vérifie la somme de contrôle → sauvegarde → migre (au démarrage de l'API, Flyway) → redémarre.
# En cas d'échec : RETOUR ARRIÈRE AUTOMATIQUE = restauration de la sauvegarde faite juste avant + ancienne image
# (Flyway n'est pas réversible : on ne « dé-migre » jamais, on restaure).
#
#   ./update.sh --version 1.4.0                    # installation faite avec --images-prebuilt (images publiques GHCR dans .env) : tire les images
#   ./update.sh --version 1.4.0 --registre ghcr.io/autre/immogest   # idem avec un autre préfixe d'images (sans sources sur le serveur, GHCR de l'éditeur par défaut)
#   ./update.sh --version 1.4.0 --verifier-signature   # idem, après contrôle de la signature cosign (cosign requis)
#   ./update.sh                                    # dernière version publiée par l'éditeur (IMMOGEST_LICENCE_SERVEUR_URL)
#   ./update.sh --archive immogest-1.4.0.tar.gz --sha256 <somme>   # hors ligne (réseau local) : archive remise sur clé USB
#   ./update.sh --url https://…/immogest-1.4.0.tar.gz --sha256 <somme> --version 1.4.0
#   ./update.sh --depuis-les-sources --version 1.4.0              # construit les images depuis ce dépôt (développement, CI)
# Option : --yes (sans confirmation).
# La somme de contrôle est vérifiée AVANT toute modification de l'installation en cours.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ARCHIVE=""; URL=""; SHA=""; VERSION=""; SOURCES=0; YES=0; VERIFIER=0; PREFIXE=""
erreur() { echo "ERREUR : $*" >&2; exit 1; }
info() { echo "==> $*"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --sha256) SHA="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --registre) PREFIXE="${2:-}"; shift 2 ;;
    --depuis-les-sources) SOURCES=1; shift ;;
    --verifier-signature) VERIFIER=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) erreur "option inconnue : $1" ;;
  esac
done

[ -f .env ] || erreur "deploy/.env introuvable : installation absente (install.sh)"
exec 8>.update.lock; flock -n 8 || erreur "une mise à jour est déjà en cours"
# Installations antérieures : s3.json était créé en 0600, illisible pour le conteneur SeaweedFS si son uid diffère de celui de l'installateur
[ -f generated/s3.json ] && chmod 0644 generated/s3.json
set -a; . ./.env; set +a
ANCIENNE="${IMMOGEST_VERSION:-latest}"
# Noms des images (registre ou locales) : ceux de .env pour une installation faite avec --images-prebuilt
IMG_app="${IMMOGEST_IMAGE_APP:-immogest/app}"; IMG_web="${IMMOGEST_IMAGE_WEB:-immogest/web}"; IMG_sauvegarde="${IMMOGEST_IMAGE_SAUVEGARDE:-immogest/sauvegarde}"
REGISTRE=0; [ -z "${IMMOGEST_IMAGE_APP:-}" ] || REGISTRE=1
# Noms avant un éventuel passage au registre : ce sont eux que le retour arrière retrouve
IMGANC_app="$IMG_app"; IMGANC_web="$IMG_web"; IMGANC_sauvegarde="$IMG_sauvegarde"
# --version X sans archive ni sources : on tire les images X du registre (--registre PREFIX, sinon celui de l'éditeur), même si cette installation
# n'en venait pas (ses noms d'images sont alors écrits dans .env)
if [ "$REGISTRE" = 0 ] && [ "$SOURCES" = 0 ] && [ -z "$ARCHIVE" ] && [ -z "$URL" ] && { [ -n "$PREFIXE" ] || { [ -n "$VERSION" ] && [ ! -f ../backend/pom.xml ]; }; }; then
  PREFIXE="${PREFIXE:-ghcr.io/fixedevelloper/immogest}"
  IMG_app="$PREFIXE-app"; IMG_web="$PREFIXE-web"; IMG_sauvegarde="$PREFIXE-sauvegarde"; REGISTRE=1
  info "Images tirées du registre : $PREFIXE-{app,web,sauvegarde}"
fi
TMP=$(mktemp -d); trap 'rm -rf "${TMP:?}"' EXIT

attendre_sain() { # attendre_sain SERVICE SECONDES
  local etat="" i
  for ((i = 0; i < $2 / 5; i++)); do
    etat=$(docker compose ps "$1" --format '{{.Health}}' 2>/dev/null || true)
    [ "$etat" = healthy ] && return 0
    sleep 5
  done
  return 1
}
integrite() { # intégrité : nombre de lignes de chaque table (hors files techniques), dans un fichier
  docker compose exec -T sauvegarde psql -At -c "
    SELECT table_name || ' ' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text
      FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
       AND table_name NOT IN ('scheduled_tasks', 'event_publication', 'notif_message', 'flyway_schema_history') ORDER BY 1" > "$1"
}

# ------------------------------------------------------------------ 1. version et archive (rien n'est modifié)
if [ "$SOURCES" = 1 ]; then
  [ -n "$VERSION" ] || erreur "--version est requis avec --depuis-les-sources"
  [ -f ../backend/pom.xml ] || erreur "sources absentes"
elif [ "$REGISTRE" = 1 ] && [ -z "$ARCHIVE" ] && [ -z "$URL" ]; then
  # Images publiques tirées du registre : rien à vérifier par somme de contrôle (le condensé des couches l'est par Docker) ;
  # on les télécharge toutes AVANT de toucher à l'installation, et on peut contrôler la signature cosign.
  if [ -z "$VERSION" ]; then
    [ -n "${IMMOGEST_LICENCE_SERVEUR_URL:-}" ] || erreur "indiquez --version X.Y.Z (pas de serveur de licences configuré pour connaître la dernière)"
    META=$(curl -fsS --max-time 20 "${IMMOGEST_LICENCE_SERVEUR_URL%/}/api/v1/versions/derniere") || erreur "serveur de licences injoignable"
    VERSION=$(printf '%s' "$META" | sed -n 's/.*"numero":"\([^"]*\)".*/\1/p')
    [ -n "$VERSION" ] || erreur "réponse du serveur de licences illisible"
  fi
  [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || erreur "version invalide : $VERSION"
  for s in app web sauvegarde; do
    var="IMG_$s"; ref="${!var}:$VERSION"
    info "Téléchargement de $ref"; docker pull -q "$ref" >/dev/null || erreur "image introuvable : $ref (version inexistante ou registre injoignable). Rien n'a été modifié."
    if [ "$VERIFIER" = 1 ]; then
      command -v cosign >/dev/null 2>&1 || erreur "--verifier-signature demande cosign (https://docs.sigstore.dev/cosign/installation/)"
      cosign verify "$ref" --certificate-identity-regexp '^https://github.com/fixedevelloper/csimmo/\.github/workflows/images\.yml@refs/tags/v' \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1 || erreur "SIGNATURE INVALIDE pour $ref : image non produite par la CI de l'éditeur. Rien n'a été modifié."
      info "Signature vérifiée : $ref"
    fi
  done
else
  if [ -z "$ARCHIVE" ] && [ -z "$URL" ]; then
    [ -n "${IMMOGEST_LICENCE_SERVEUR_URL:-}" ] || erreur "aucune archive indiquée et pas de serveur de licences configuré (installation hors ligne : --archive)"
    info "Recherche de la dernière version publiée"
    META=$(curl -fsS --max-time 20 "${IMMOGEST_LICENCE_SERVEUR_URL%/}/api/v1/versions/derniere") || erreur "serveur de licences injoignable"
    VERSION=$(printf '%s' "$META" | sed -n 's/.*"numero":"\([^"]*\)".*/\1/p')
    URL=$(printf '%s' "$META" | sed -n 's/.*"urlTelechargement":"\([^"]*\)".*/\1/p')
    SHA=$(printf '%s' "$META" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
    [ -n "$VERSION" ] && [ -n "$URL" ] && [ -n "$SHA" ] || erreur "réponse du serveur de licences illisible"
  fi
  [ -n "$SHA" ] || erreur "--sha256 est obligatoire : on n'installe jamais une archive non vérifiée"
  [[ "$SHA" =~ ^[0-9a-fA-F]{64}$ ]] || erreur "somme de contrôle invalide"
  if [ -n "$URL" ]; then
    [[ "$URL" =~ ^https:// ]] || erreur "le téléchargement doit se faire en https"
    info "Téléchargement de $URL"
    ARCHIVE="$TMP/archive.tar.gz"; curl -fSL --max-time 3600 -o "$ARCHIVE" "$URL" || erreur "téléchargement impossible"
  fi
  [ -f "$ARCHIVE" ] || erreur "archive introuvable : $ARCHIVE"
  CALCULEE=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
  [ "${CALCULEE,,}" = "${SHA,,}" ] || erreur "SOMME DE CONTRÔLE INVALIDE (attendue $SHA, obtenue $CALCULEE) : l'archive est corrompue ou falsifiée. Rien n'a été modifié."
  info "Somme de contrôle vérifiée"
  mkdir "$TMP/x"; tar -xzf "$ARCHIVE" -C "$TMP/x"
  [ -f "$TMP/x/images.tar" ] && [ -f "$TMP/x/deploy/docker-compose.yml" ] || erreur "archive invalide (images.tar ou deploy/ manquant)"
  if [ -z "$VERSION" ]; then
    VERSION=$(tar -xOf "$TMP/x/images.tar" manifest.json | grep -o 'immogest/app:[^"]*' | head -n1 | cut -d: -f2)
  fi
fi
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || erreur "version invalide : $VERSION"
info "Version installée : $ANCIENNE → nouvelle version : $VERSION"
if [ "$YES" != 1 ]; then read -r -p "Continuer ? L'application sera indisponible quelques minutes [o/N] : " r; [ "${r,,}" = o ] || { echo annulé; exit 1; }; fi

# ------------------------------------------------------------------ 2. sauvegarde d'avant migration
docker compose ps --status running --services | grep -qx sauvegarde || erreur "le service de sauvegarde ne tourne pas : mise à jour refusée (aucune sauvegarde possible)"
info "Sauvegarde avant mise à jour"
docker compose exec -T sauvegarde /opt/sauvegarde/sauvegarder.sh avant-mise-a-jour || [ $? -eq 3 ] || erreur "la sauvegarde a échoué : mise à jour annulée, rien n'a été modifié"
SAUVEGARDE_ID=$(docker compose exec -T sauvegarde sh -c 'ls -1d /sauvegardes/*-avant-mise-a-jour | sort | tail -n1' | tr -d '\r' | xargs -n1 basename)
[ -n "$SAUVEGARDE_ID" ] || erreur "sauvegarde introuvable"
integrite "$TMP/avant.txt"
info "Sauvegarde $SAUVEGARDE_ID faite"

# ------------------------------------------------------------------ 3. mise en place
for s in app web sauvegarde; do var="IMGANC_$s"; docker image inspect "${!var}:$ANCIENNE" >/dev/null 2>&1 && docker tag "${!var}:$ANCIENNE" "${!var}:avant-mise-a-jour"; done
FICHIERS="docker-compose.yml Caddyfile.domaine Caddyfile.local Caddyfile.tunnel install.sh update.sh backup.sh restore.sh package-release.sh diagnostic.sh"
rm -rf .avant-mise-a-jour; mkdir .avant-mise-a-jour
for f in $FICHIERS .env; do [ -f "$f" ] && cp -p "$f" .avant-mise-a-jour/; done
if [ "$SOURCES" = 1 ]; then
  info "Construction des images $VERSION"; IMMOGEST_VERSION="$VERSION" docker compose build
elif [ -z "$ARCHIVE" ] && [ "$REGISTRE" = 1 ]; then
  info "Images $VERSION déjà téléchargées"
else
  info "Chargement des images"; docker load -i "$TMP/x/images.tar" >/dev/null
  # installation faite avec des images de registre : l'archive les livre sous immogest/<nom>, on les range sous les noms du .env
  if [ "$REGISTRE" = 1 ]; then for s in app web sauvegarde; do var="IMG_$s"; docker tag "immogest/$s:$VERSION" "${!var}:$VERSION"; done; fi
  for f in $FICHIERS; do [ -f "$TMP/x/deploy/$f" ] && cp "$TMP/x/deploy/$f" "./$f"; done
fi

retour_arriere() {
  echo "ÉCHEC de la mise à jour : $1" >&2
  echo "==> Retour arrière : restauration de la sauvegarde $SAUVEGARDE_ID et de l'ancienne version $ANCIENNE" >&2
  docker compose stop app web >&2 || true
  for f in $FICHIERS .env; do [ -f ".avant-mise-a-jour/$f" ] && cp -p ".avant-mise-a-jour/$f" "./$f"; done
  for s in app web sauvegarde; do var="IMGANC_$s"; docker image inspect "${!var}:avant-mise-a-jour" >/dev/null 2>&1 && docker tag "${!var}:avant-mise-a-jour" "${!var}:$ANCIENNE"; done
  set -a; . ./.env; set +a
  docker compose up -d sauvegarde >&2
  sleep 5
  if docker compose exec -T -e FORCER_VERSION=1 sauvegarde /opt/sauvegarde/restaurer.sh "$SAUVEGARDE_ID" >&2 && docker compose up -d app web >&2 && attendre_sain app 240; then
    echo "Retour arrière réussi : ImmoGest $ANCIENNE fonctionne avec les données d'avant la mise à jour." >&2
  else
    echo "LE RETOUR ARRIÈRE AUTOMATIQUE A ÉCHOUÉ. Vos données sont dans la sauvegarde $SAUVEGARDE_ID (volume « sauvegardes »)." >&2
    echo "Restauration manuelle : FORCER_VERSION=1 ./restore.sh $SAUVEGARDE_ID  (après avoir vérifié IMMOGEST_VERSION=$ANCIENNE dans .env)" >&2
  fi
  exit 1
}

# ------------------------------------------------------------------ 4. migration + redémarrage
info "Redémarrage en version $VERSION (les migrations de base s'exécutent au démarrage)"
sed -i "s/^IMMOGEST_VERSION=.*/IMMOGEST_VERSION=$VERSION/" .env
if [ "$REGISTRE" = 1 ]; then # noms des images du registre mémorisés (remplacés s'ils existent, sinon ajoutés)
  for pair in "APP:$IMG_app" "WEB:$IMG_web" "SAUVEGARDE:$IMG_sauvegarde"; do
    cle="IMMOGEST_IMAGE_${pair%%:*}"; val="${pair#*:}"
    if grep -q "^$cle=" .env; then sed -i "s|^$cle=.*|$cle=$val|" .env; else printf '%s=%s\n' "$cle" "$val" >> .env; fi
  done
fi
set -a; . ./.env; set +a
docker compose up -d || retour_arriere "démarrage impossible"
attendre_sain app 300 || retour_arriere "l'application ne démarre pas (migration en échec ?)"
attendre_sain web 120 || retour_arriere "l'interface web ne démarre pas"
docker compose ps --status running --services | grep -qx sauvegarde || retour_arriere "le service de sauvegarde ne tourne plus"
[ "${IMMOGEST_TEST_ECHEC:-}" != apres-migration ] || retour_arriere "échec simulé (IMMOGEST_TEST_ECHEC)"

# ------------------------------------------------------------------ 5. contrôle d'intégrité
info "Contrôle d'intégrité des données"
integrite "$TMP/apres.txt"
# fichier 1 = après, fichier 2 = avant : on signale toute table disparue ou dont le nombre de lignes a baissé
MANQUE=$(awk 'NR==FNR {apres[$1]=$2; next} { if (!($1 in apres)) print $1 " (table disparue)"; else if (apres[$1] < $2) print $1 " (" $2 " → " apres[$1] " lignes)" }' "$TMP/apres.txt" "$TMP/avant.txt" | head -n5)
[ -z "$MANQUE" ] || retour_arriere "des données ont disparu : $MANQUE"
curl_ok=$(docker compose exec -T app curl -fsS http://localhost:8080/api/v1/health >/dev/null 2>&1 && echo oui || echo non)
[ "$curl_ok" = oui ] || retour_arriere "l'API ne répond pas"

echo
echo "ImmoGest est à jour : $ANCIENNE → $VERSION. Sauvegarde d'avant mise à jour conservée : $SAUVEGARDE_ID."
