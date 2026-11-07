# ImmoGest : fichiers d'installation chez le client

Copie réduite de `deploy/` : uniquement ce qui sert sur le serveur du client. Les images viennent de GHCR (publiques), rien n'est construit ici.

```bash
./install.sh --mode domaine --site immo.exemple.cm --version 1.4.0 --images-prebuilt --yes
./update.sh --version 1.4.0 [--verifier-signature]
./backup.sh | ./restore.sh <id> | ./diagnostic.sh
```

Détails (modes, sauvegardes, restauration, mise à jour) : `deploy/README.md` du dépôt.
**Copiez `.env` hors du serveur** : sans `IMMOGEST_CLE_CHIFFREMENT`, les pièces d'identité chiffrées sont irrécupérables.

Ces fichiers sont des copies de `deploy/` : toute modification des scripts, du compose ou des Caddyfile se fait dans `deploy/`, puis se recopie ici.
