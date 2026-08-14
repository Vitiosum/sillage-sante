# CLAUDE.md — Sillage Santé

## Objectif du dépôt

**Ce dépôt est le support d'une démo de migration Supabase Cloud → Clever Cloud.**

Il n'est pas un produit à faire vivre. C'est un cas de test : une application
qui exploite volontairement une large surface Supabase (PostgREST, GoTrue,
Storage, Realtime, Edge Functions, pg_cron, pg_net, Vault, pgmq, PostGIS,
pgvector), pour démontrer comment on la reprend sur Clever Cloud.

Contexte : avant-vente Clever Cloud. Audience technique et décideurs. Le
livrable attendu est un **plan de migration défendable**, puis une **cible qui
tourne**. Time-to-demo court, architecture lisible.

## Les deux phases

### Phase 1 — Faire vivre la source (Supabase Cloud) — **terminée**

Objectif : un système réellement déployé, avec des données, pour produire les
dumps qui serviront de matière à la migration. Procédure complète dans
[DEPLOIEMENT.md](DEPLOIEMENT.md).

**Projet de démo** : `hdhmnoliwhsqiuawqrnp`, région `eu-west-1` (Irlande),
PostgreSQL 17.6, plan gratuit.
[Dashboard](https://supabase.com/dashboard/project/hdhmnoliwhsqiuawqrnp)

La région n'est pas `eu-west-3` comme le suggère DEPLOIEMENT.md. On la garde :
« la source est en Irlande, la cible Clever Cloud sera en France » est un angle
utile pour la démo, pas un défaut à corriger.

#### Ce qui est déployé

| Étape | Commande | État |
|---|---|---|
| Liaison | `supabase link --project-ref hdhmnoliwhsqiuawqrnp` | fait |
| Migrations | `supabase db push --include-all` | fait — **16/16**, dont 4 correctifs datés du 13 août |
| Config projet | `NEXT_PUBLIC_SITE_URL=http://localhost:3000 supabase config push` | fait — api, db, auth, storage `up_to_date` |
| 5 Edge Functions | `supabase functions deploy` | fait, les 5 `ACTIVE` |
| Secrets fonctions | `supabase secrets set --env-file …` | fait — 3 poussés |
| Database Webhooks | Integrations → Database Webhooks → Install | fait |
| Secret du Vault | `./scripts/post-deploiement.sh <ref>` | fait — `service_role_key` posé |
| Comptes de test | `./scripts/comptes-demo.sh` | fait — 3 comptes |
| Données de démo | `psql "$SUPABASE_DB_URL" -f scripts/donnees-demo.sql` | fait |
| Dumps | `pg_dump` natif | fait — 3 fichiers |

#### La chaîne tourne réellement

Vérifié, pas déduit. Un `update medical.rendez_vous set statut = 'confirme'`
déclenche `rdv_confirme_webhook` → `supabase_functions.http_request` →
`pg_net` → Edge Function `rappel-rdv`, qui répond `200 {"traites":1}`. En
parallèle, le job `pg_cron` `traiter-files` s'exécute seul toutes les 5
minutes en lisant la clé `service_role` dans le Vault. Les réponses sont
lisibles dans `net._http_response`.

C'est la boucle complète — cron, pg_net, Vault, PostgREST, Edge Functions —
et c'est elle qu'il faut reconstituer sur Clever Cloud.

#### Relevé réel en base

| | |
|---|---|
| Tables | 16 (15 `medical` + 1 `audit`) |
| Extensions | **16**, dont `postgis` 3.3.7, `vector` 0.8.2, `pgmq` 1.5.1, `pg_cron` 1.6.4, `pg_net` 0.20.4, `supabase_vault` 0.3.1, **`pgsodium` 3.1.8**, `pgjwt` 0.2.0 |
| Policies | 55 (`medical`, `storage`, `realtime`, `public`) |
| Buckets | 4 — `avatars`, `documents-medicaux`, `imagerie`, `ordonnances` |
| Realtime | 3 tables publiées |
| Jobs cron | 3 (5 après `post-deploiement.sql`) |

**`pgsodium` est bien là.** DEPLOIEMENT.md annonçait qu'il n'était plus
provisionné : faux sur un projet créé en août 2026. Le chiffrement TCE de
`patients.nir_chiffre` est donc **actif**, et le point dur n°1 du README se
démontre en conditions réelles — c'est mieux pour la démo, et ça change
l'arbitrage : on ne migre pas un chiffrement théorique, on migre un
`security label` qui existe et qui ne se restaure pas par `pg_restore`.

Astuce de relevé, faute de Docker et de mot de passe : une migration jetable
qui `raise exception` renvoie l'état dans la sortie de `db push`, et la
transaction est annulée. Détail dans DEPLOIEMENT.md.

#### Correctif appliqué : droits du hook GoTrue

`supabase config push` active le hook `custom_access_token`. Or
`20260114090500_auth_hook_claims.sql` oubliait deux choses, et la fonction est
`stable` et non `security definer` — elle s'exécute donc avec les droits de
`supabase_auth_admin` :

- pas de `grant usage on schema medical` → `permission denied for schema
  medical`, GoTrue rend **HTTP 500 à chaque émission de jeton**. Plus aucune
  connexion possible, ni patient ni praticien ;
- policy de lecture créée sur `medical.profils` seulement, pas sur
  `praticiens` ni `patients` → les deux `select … into` renvoyaient zéro ligne
  en silence, donc `praticien_id` et `patient_id` absents du JWT.

Corrigé par `20260813120000_hook_grants_medical.sql`, qui se termine par un
bloc d'assertion sur `has_schema_privilege` / `has_table_privilege` : la
migration échoue si les droits ne sont pas effectifs. Elle est passée.

Le bug préexistait — la procédure demandait d'activer le hook à la main, donc
n'importe qui l'aurait touché. C'est un bon exemple de ce que la démo doit
montrer : la surface Supabase cache des dépendances de droits invisibles tant
qu'on n'exécute pas.

#### Ce que l'exécution réelle a corrigé dans la procédure

Sept écarts entre DEPLOIEMENT.md et ce qui se passe vraiment. Ils sont corrigés
dans le dépôt, et ils comptent : ce sont des frictions que la migration
retrouvera.

1. **`templates/` était absent du dépôt.** `config.toml` référençait
   `templates/magic_link.html` et `templates/invite.html` : *toute* commande CLI
   échouait au chargement de la config (`LegacyDbConfigLoadError`). Les deux
   gabarits ont été écrits.
2. **`npm install -g supabase` n'est plus supporté.** Passer par
   `brew install supabase/tap/supabase`.
3. **`--include-all` est nécessaire.** Les migrations sont horodatées en
   janvier ; un projet créé plus tard les ignore sans ce flag.
4. **`prerequis.sql` n'est pas indispensable.** PostGIS et pgmq sont créés par
   leurs propres migrations (`..._geolocalisation.sql:11`,
   `..._webhooks_et_files.sql:40`), et le reste est dans des blocs tolérants.
   Il reste recommandé pour les GRANTs de `pg_cron`.
5. **`supabase config push` remplace l'activation manuelle du hook.** L'étape
   « Authentication → Hooks » de DEPLOIEMENT.md n'est plus nécessaire : la CLI
   applique `[auth.hook.custom_access_token]`. Elle applique aussi l'auth
   anonyme, la liaison manuelle d'identités et la MFA.
6. **Le bloc `[auth]` est poussé en un seul appel.** Trois sections le
   faisaient échouer en entier, hook compris :
   - les gabarits d'e-mail — le plan gratuit les refuse sans SMTP custom
     (`400 Email template modification is not available for free tier`) ;
   - `[auth.email.smtp]` et les providers OIDC — la CLI **ne résout pas** les
     `env()` absents, elle pousse la chaîne `"env(SMTP_USER)"` littéralement.
   Les trois sont commentés ou désactivés dans `config.toml`, avec la raison.
7. **`--no-verify-jwt` est du bruit en CLI 2.x.** Après `supabase functions
   deploy` sans aucun flag, `functions list` renvoie exactement les
   `verify_jwt` de `config.toml`. C'est la config qui fait foi.

#### Les dumps : ce qu'ils disent déjà

Produits avec `pg_dump` natif via le Session pooler (`aws-1-eu-west-1`,
compatible IPv4 — la connexion directe est IPv6 par défaut). `supabase db
dump` n'a pas servi : il lance `pg_dump` dans un conteneur et Docker est
absent de la machine.

```bash
pg_dump "$SUPABASE_DB_URL" --schema-only --schema=medical --schema=audit --schema=auth_hooks --schema=public -f dump_schema.sql
pg_dump "$SUPABASE_DB_URL" --data-only --schema=medical --schema=audit -f dump_data.sql
pg_dump "$SUPABASE_DB_URL" --schema=auth --schema=storage -f dump_auth.sql
```

Premier dépouillement de `dump_schema.sql` — c'est la liste des choses qui ne
se restaurent pas telles quelles :

| Ce qu'on trouve | Occurrences | Conséquence sur la cible |
|---|---|---|
| `SECURITY LABEL FOR pgsodium ON COLUMN medical.patients.nir_chiffre` | 1 | échoue sans pgsodium : c'est le point dur n°1, et il est bien réel |
| `postgres` | 287 | propriétaire de tout ; porte **BYPASSRLS** sur Supabase, pas acquis ailleurs |
| `authenticated` / `anon` / `service_role` | 72 / 38 / 31 | doivent préexister, et `authenticator` doit pouvoir les endosser |
| `supabase_admin` | 15 | rôle de l'image Supabase, sans équivalent |
| `supabase_auth_admin` | 9 | GoTrue ; le hook et ses GRANTs en dépendent |
| `supabase_functions.http_request` | 2 | surcouche dashboard, à réécrire |
| `vault.decrypted_secrets` | 2 | à remplacer par des variables d'environnement |
| `pgsodium.crypto_aead_det_encrypt` / `_decrypt` | 2 | bascule vers `lib/chiffrement.ts` |
| `pgmq.send` / `pgmq.read`, `net.http_post` | 3 | files et appels sortants à sortir de la base |

Les dumps sont couverts par `.gitignore` (`dump_*.sql`) : ils contiennent des
données et les secrets du Vault.

#### Ce qui n'a pas pu être scripté depuis cette machine

- **Les clés d'API et le mot de passe de la base.** Seul l'humain les récupère
  dans le dashboard. Le mot de passe n'est affiché qu'à la création du projet ;
  passé ce point, la seule option est **Reset database password**.
- **L'installation d'un module d'Integrations** (ici Database Webhooks) :
  bouton du dashboard, pas d'équivalent CLI.

En revanche, tout le reste s'est fait en ligne de commande — y compris ce que
DEPLOIEMENT.md donnait pour manuel (activation du hook GoTrue, jobs cron,
trigger de webhook), une fois `config push` et les migrations bien employés.

#### Charge et recette

Le corpus ne se limite plus à trois lignes. Enchaînement complet :

```bash
./scripts/comptes-demo.sh                                    # 3 comptes GoTrue
psql "$SUPABASE_DB_URL" -f scripts/donnees-demo.sql          # repare les roles, pose le jeu de base
psql "$SUPABASE_DB_URL" -v n=20000 -f scripts/volume-demo.sql # 20k consultations + embeddings
./scripts/objets-demo.py                                     # objets dans les 4 buckets
./scripts/sessions-mfa.py                                    # sessions reelles + TOTP (aal2)
./scripts/recette-rls.py                                     # matrice RLS par identite
```

État atteint : 20 001 consultations dont 20 000 avec embedding `vector(1536)`,
20 003 rendez-vous, 501 patients, 5 objets Storage, 6 sessions, 1 facteur TOTP.
Base : **363 Mo**.

`recette-rls.py` est le **test de recette de la migration** : rejoué sur
Clever Cloud, une matrice identique vaut preuve de reprise fidèle.

Les chiffres de la fenêtre de bascule et les quatre plafonds rencontrés
(`maintenance_work_mem` 32 Mo, `statement_timeout` 2 min, 500 Mo de plan
gratuit, bloat MVCC) sont dans
[CONSTATS-DEPLOIEMENT.md](CONSTATS-DEPLOIEMENT.md).

Puis, une fois le corpus charge :

```bash
supabase db dump -f dump_schema.sql
supabase db dump -f dump_data.sql --data-only
supabase db dump -f dump_auth.sql --schema auth,storage
```

Ces trois fichiers sont l'entrée de la phase 2.

### Phase 2 — La cible (Clever Cloud) — c'est le livrable

Reprendre la même application sur Clever Cloud, en écartant ce qui n'est pas
portable et en assumant les arbitrages à voix haute. Ce qu'on ne migre pas doit
être justifié, pas passé sous silence.

Les 18 points durs sont listés dans la section « Points volontairement
difficiles » du [README](README.md). **Un plan de migration qui n'en mentionne
pas au moins la majorité est incomplet.**

À lire avant d'attaquer la cible :
[CONSTATS-DEPLOIEMENT.md](CONSTATS-DEPLOIEMENT.md) — 25 constats retenus sur 93
instruits, recroisés avec l'état réel de la base. C'est la matière brute du plan
de migration, et la preuve que sur cette surface rien ne se déduit : tout se
relève.

## Cartographie Supabase → Clever Cloud

La colonne « source » est relevée sur le projet déployé. La colonne « cible »
est désormais adossée à la documentation Clever Cloud, vérifiée en août 2026 —
192 faits collectés, **116 confirmés après réfutation adverse**. Détail et
sources : `~/.claude/skills/migration-supabase-clever/references/clever-cloud.md`.

### Le constat qui tranche avant tous les arbitrages

**L'add-on PostgreSQL managé n'autorise ni superuser, ni création de rôles, ni
réplication logique.** La documentation liste explicitement comme impossibles
l'administration d'utilisateurs, la mise à jour de la configuration serveur et
la création de réplicas.

Or cette application exige des rôles dédiés : `authenticator` + `anon` +
`authenticated` + `service_role` pour PostgREST, `supabase_auth_admin` pour
GoTrue, `supabase_storage_admin` pour Storage, un rôle `REPLICATION` pour
Realtime. **La stack Supabase ne peut donc pas être redéployée telle quelle sur
l'add-on managé.**

Trois voies, par ordre de préférence :

1. **On ne migre pas Supabase, on migre l'application.** Un backend classique
   remplace PostgREST + GoTrue + Realtime et parle directement à l'add-on. Trois
   conteneurs disparaissent. C'est la réponse la plus simple, la plus native, et
   la moins coûteuse à exploiter — **c'est la recommandation par défaut**.
2. **PostgreSQL sur CKE** si la stack doit être conservée à l'identique : on
   récupère le contrôle complet, on perd le managé.
3. **Add-on dédié + tickets support**, à qualifier. Ne rien promettre sans
   réponse écrite.

### Extensions : ce qui existe et ce qui n'existe pas

L'add-on fournit **47 extensions par défaut** et **10 sur ticket**. La liste
« à la demande » est fermée.

| Extension utilisée ici | Chez Clever Cloud |
|---|---|
| `postgis` 3.3.7 | **par défaut** |
| `vector` 0.8.2 | **par défaut** — `pgvector` figure dans les extensions livrées |
| `pgcrypto`, `uuid-ossp`, `pg_trgm`, `btree_gist`, `unaccent` | **par défaut** |
| `pg_cron` 1.6.4, `pg_net` 0.20.4 | **sur ticket** |
| **`pgsodium`, `supabase_vault`, `pgmq`, `pgjwt`, `pg_graphql`** | **indisponibles** |

Cinq des extensions de ce projet n'ont donc **aucune cible**. C'est le point de
bascule du plan, et il est tranché : il faut réécrire, pas porter.

| Brique | Source, mesurée | Cible Clever Cloud envisagée | Statut |
|---|---|---|---|
| PostgreSQL | 17.6, 16 tables, 55 policies | Add-on PostgreSQL (14 à 18 supportées) | natif — mais voir la contrainte de rôles ci-dessus |
| Chiffrement TCE du NIR | `SECURITY LABEL FOR pgsodium ON COLUMN medical.patients.nir_chiffre` | **aucune cible** — `pgsodium` indisponible | **tranché** : chiffrement applicatif (`lib/chiffrement.ts`), ou `pgcrypto` |
| Rôles | `postgres` porte **BYPASSRLS** ; `authenticated`/`anon`/`service_role` cités 141 fois ; `supabase_admin` 15 fois | **impossible à recréer sur l'add-on managé** | **le point qui décide de l'architecture cible** |
| PostgREST | schémas exposés : `public`, `graphql_public`, `medical` | `postgrest/postgrest:v16.1`, port 3000 — **ou suppression pure** | recommandé : **supprimer**, au profit d'un backend applicatif |
| GoTrue | hook `custom_access_token`, MFA TOTP, auth anonyme, liaison d'identités, OIDC Pro Santé Connect | **Add-on Keycloak** (natif), ou `supabase/auth` en Docker | Keycloak évite un conteneur à exploiter |
| Storage | 4 buckets — `avatars` 2 Mio, `documents-medicaux` 50 Mio, `ordonnances` 5 Mio, `imagerie` 5 Gio | **Cellar** | natif. L'API Storage n'est nécessaire que si les policies RLS sur objets le sont |
| Transformation d'image | `getPublicUrl(..., { transform })` | `ghcr.io/imgproxy/imgproxy:v4.0.12`, port 8080 | conteneur le plus simple ; **signer les URL**, désactivé par défaut |
| Upload reprenable TUS | segments de 6 Mio imposés | à valider derrière le load balancer | à tester |
| Realtime | 3 tables publiées, `replica identity full`, policies sur `realtime.messages` | `supabase/realtime:v2.126.0` — **Postgres Changes hors d'atteinte sur l'add-on managé** (pas de `wal_level=logical`) | Broadcast et Presence, eux, ne dépendent pas du décodage logique : **vérifier lesquels sont réellement utilisés avant de renoncer** |
| Edge Functions | 5 fonctions Deno, 3 secrets | Applications Clever Cloud (Docker/Node) | 1 app, ou 5 endpoints d'une app |
| `pg_cron` | **5 jobs**, tous actifs | `clevercloud/cron.json` (disponible sur ticket si on veut le garder en base) | **sortir la logique de la base**. Piège : les crons s'exécutent sur **chaque scaler** — dédupliquer sur `INSTANCE_NUMBER` |
| `pg_net` | appel sortant en trigger ; réponses dans `net._http_response` | Appel HTTP applicatif (disponible sur ticket sinon) | même logique : sortir de la base |
| `supabase_vault` | 3 secrets, dont `service_role_key` lu par les jobs cron | **indisponible** → variables d'environnement | natif, `clever env import` |
| `pgmq` | 3 files, trigger d'empilement | **indisponible** → add-on Pulsar, ou table de file + `pg_cron` | tranché : Pulsar est natif |
| Database Webhooks | schéma `supabase_functions`, fonction trigger `http_request()` sans argument déclaré (TG_ARGV), rôle `supabase_functions_admin` | surcouche maison à `pg_net` | à réécrire côté application |
| `pg_graphql` | 1.6.1, activée, **aucun appel dans le code** | aucune cible | **à ne pas porter**, et à le dire |
| Clés | `anon` publishable, `service_role` secret, JWT secret | Variables d'environnement, JWT à régénérer de façon cohérente | à reprendre en entier |

### Deux pièges de plateforme, vérifiés

- **Il n'existe pas de fichier `clever.json`.** Aucun manifeste de déploiement
  équivalent à `fly.toml`. La configuration passe par les variables `CC_*`, les
  fichiers natifs du langage, et `clevercloud/*.json`. `.clever.json` (avec le
  point) est un fichier de liaison local de la CLI, non lu par la plateforme.
- **Les crons s'exécutent sur chaque scaler.** Avec trois instances, une tâche
  part trois fois. Le clustering n'est pas supporté : la déduplication est à la
  charge de l'application, sur `INSTANCE_NUMBER`. C'est le piège n°1 quand on
  remplace `pg_cron` par du cron Clever Cloud — en base, le job tournait une
  fois.

Face à l'empilement de conteneurs (PostgREST + GoTrue + Realtime + imgproxy) :
**Kubernetes Clever Cloud (CKE)** pour héberger la stack, avec les add-ons
managés à côté. Mais la première question reste : **a-t-on vraiment besoin de
cette stack ?** Un backend applicatif classique la remplace et supprime quatre
conteneurs.

### Outillage réutilisable

La méthode générique, l'outillage et les gabarits de déploiement sont
disponibles comme skill : `~/.claude/skills/migration-supabase-clever/`,
invocable par `/migration-supabase-clever`. Le cas travaillé ici est dans
[PROCEDURE-MIGRATION.md](PROCEDURE-MIGRATION.md).

## HDS — ce qui contraint l'architecture

Le scénario de la démo est HDS. Points contre-expertisés (12 affirmations, un
réfuteur chacune, sources primaires) — fiche complète dans
`~/.claude/skills/migration-supabase-clever/references/hds.md`.

### La zone se choisit à la création, et ne se rattrape pas

**`par`, la zone par défaut, n'est pas HDS** — alors qu'elle tourne dans les
mêmes datacenters parisiens que `parhds` et partage ses plages d'IP sortantes.
Une application créée sans `--region parhds` est hors périmètre certifié tout
en étant « à Paris ». **Aucun signal à l'exécution** : ça marche, rien n'alerte.

Zones ouvertes au déploiement applicatif : `parhds`, `grahds`, `rbxhds`.

**Et la zone ne suffit pas** : l'hébergement certifié suppose zone HDS **et**
contrat HDS signé. Devant un client, dire *« zone HDS + contrat HDS signé »*,
jamais *« déployé en région HDS, donc conforme »*.

### Trois croyances fausses à ne pas répéter

Le référentiel HDS v2.0 **n'impose ni le chiffrement au repos, ni la MFA, ni
aucune durée de conservation des journaux** — zéro occurrence de ces notions
dans le texte. Ces obligations existent, mais viennent d'ailleurs : référentiel
CNIL entrepôts pour le chiffrement, arrêté PGSSI-S du 28 mars 2022 pour
l'authentification forte, contrat pour les durées. Les attribuer au HDS fait
perdre la discussion dès qu'un juriste ouvre le référentiel.

**Piège documentaire** : le PDF « Référentiel HDS v2.1 — version en
concertation » est le premier résultat des moteurs sur esante.gouv.fr. Il est
en mode révision et **n'est pas opposable**. Le texte en vigueur est la **v2.0**
(arrêté du 26 avril 2024). Il a piégé 9 vérifications sur 12.

### Ce que ça change pour ce projet

- **Le journal d'audit devient un composant à part entière.** La durée de
  conservation relève du responsable de traitement et se fixe **au contrat**,
  pas du référentiel. Or ici il pesait déjà 268 Mo pour 40 001 lignes, plus
  lourd que les données tracées, avec une purge à trois ans qui ne se
  déclenchait jamais. À dimensionner en conception.
- **Le chiffrement au repos de PostgreSQL** n'est disponible que sur les plans
  **dédiés**, n'est **pas actif par défaut**, et s'active sur ticket support.
  À demander au provisionnement.
- **La MFA TOTP du parcours praticien** relève de l'application, pas de
  l'hébergement. Elle reste justifiée — mais par l'analyse de risque et
  l'arrêté PGSSI-S, pas par le HDS.

## Règles de travail

- **Clever Cloud first.** Toujours proposer la solution la plus native et la
  plus simple. Un add-on managé bat un conteneur auto-hébergé.
- **Pas de contournement inutile**, pas de complexité non justifiée.
- **Vérifier avant d'affirmer.** La disponibilité d'une extension, d'un runtime
  ou d'un comportement se contrôle, elle ne se suppose pas.
- **Nommer ce qu'on ne migre pas.** Un composant écarté avec sa raison vaut
  mieux qu'un composant porté par réflexe.
- Réflexes systématiques : compatibilité build, compatibilité runtime,
  structure du projet, commande de démarrage, variables d'environnement,
  intégration des add-ons, faisabilité réelle.

## Ce dépôt n'a pas vocation à être « corrigé »

Les points durs sont **volontaires**. Ne pas les supprimer, ne pas les
contourner en amont : ils sont la matière de la démo. Le travail consiste à les
traiter dans le plan de migration et dans la cible Clever Cloud, pas à les
retirer de la source.

Aucune donnée réelle, aucun secret valide. `.env.local` n'est jamais versionné.

### Une exception : le dépôt est public

`scripts/post-deploiement.sql` demandait de remplacer `<SERVICE_ROLE_KEY>`
**dans le fichier suivi par git**, alors que le workflow documenté est
`git add .`. Sur un dépôt public, c'est une fuite de clé au commit suivant —
et `service_role` contourne toutes les policies RLS.

Corrigé : le `.sql` porte un avertissement et ne doit plus être édité. Passer
par `./scripts/post-deploiement.sh <project-ref>`, qui lit la clé dans
`.env.local` et génère `post-deploiement.local.sql` (ignoré par git, en 600).

`.gitignore` couvre désormais `*.local.sql`, `dump_*.sql` et `.env.*.local`.
**Avant tout commit, vérifier :**

```bash
git ls-files | grep -Ei 'env|dump|local\.sql'
```

## Commandes

```bash
# Source (Supabase)
supabase link --project-ref <ref>
supabase db push
supabase functions deploy <nom>
supabase db dump -f dump_schema.sql

# Cible (Clever Cloud)
clever login
clever applications
clever env set <VAR> <valeur>
clever deploy
clever logs
```

## Workflow

```bash
git add .
git commit -m "description"
git push
```
