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

### Phase 1 — Faire vivre la source (Supabase Cloud) — **en cours**

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
| 12 migrations | `supabase db push --include-all` | fait, aucune erreur |
| Config projet | `NEXT_PUBLIC_SITE_URL=http://localhost:3000 supabase config push` | fait — api, db, auth, storage `up_to_date` |
| 5 Edge Functions | `supabase functions deploy` | fait, les 5 `ACTIVE` |
| Secrets fonctions | `supabase secrets set --env-file …` | **à faire** — dépend de `.env.local` |
| `post-deploiement.sql` | `./scripts/post-deploiement.sh <ref>` | **à faire** — dépend de `.env.local` |
| Comptes de test | SQL Editor, étape 7 de DEPLOIEMENT.md | **à faire** |

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

#### Ce qui n'est pas scriptable depuis cette machine

- **`supabase db dump` exige Docker**, absent ici. `pg_dump` et `psql` natifs
  sont disponibles mais réclament le mot de passe de la base. Les trois dumps
  de la phase 2 passent donc par un `SUPABASE_DB_URL` renseigné dans
  `.env.local`, ou par l'installation de Docker Desktop.
- **Les clés d'API du projet** (`anon`, `service_role`) : à récupérer dans
  Project Settings → API et à coller dans `.env.local`.

Puis, une fois deux ou trois consultations saisies :

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

## Cartographie Supabase → Clever Cloud (hypothèse de travail)

À valider composant par composant pendant le POC — rien ici n'est acquis avant
vérification sur la plateforme.

| Brique Supabase | Cible Clever Cloud envisagée | Statut |
|---|---|---|
| PostgreSQL | Add-on PostgreSQL | natif |
| Extensions (`postgis`, `vector`, `pg_cron`, `pg_net`, `pgsodium`, `pgmq`, `pgjwt`, `supabase_vault`) | Add-on PostgreSQL | **à vérifier une par une** — c'est le point de bascule du plan |
| PostgREST | Application Docker | à déployer |
| GoTrue (auth, MFA, OIDC, anonyme) | Add-on Keycloak, ou GoTrue en Docker | arbitrage à poser |
| Storage API + buckets | Cellar (S3-compatible) | natif, mais l'API Storage Supabase est une surcouche |
| Transformation d'image (`transform`) | imgproxy en application Docker | conteneur supplémentaire |
| Upload reprenable TUS | à valider derrière le load balancer Clever Cloud | à tester |
| Realtime (postgres_changes, broadcast, presence) | Application Docker dédiée | poste le plus coûteux |
| Edge Functions (Deno) | Applications Clever Cloud (Docker/Node) | 1 app, ou 5 endpoints d'une app |
| `pg_cron` (4 jobs) | Cron Clever Cloud (`clevercloud/cron.json`) | **sortir la logique de la base** — plus simple et plus lisible |
| `pg_net` (appel sortant en trigger) | Appel HTTP applicatif | même logique : sortir de la base |
| `supabase_vault` (3 secrets) | Variables d'environnement Clever Cloud | natif, `clever env set` |
| `pgmq` (3 files) | Add-on Pulsar, ou `pgmq` conservé en base | arbitrage à poser |
| Database Webhooks (`supabase_functions.http_request`) | Surcouche dashboard, pas de PostgreSQL standard | à réécrire côté application |
| `pg_graphql` | Aucune cible — activé mais jamais appelé dans le code | **à ne pas porter**, et à dire |
| Clés `anon` / `service_role` / `SUPABASE_JWT_SECRET` | Variables d'environnement + JWT à régénérer de façon cohérente | à reprendre en entier |

Option à considérer face à l'empilement de conteneurs (PostgREST + GoTrue +
Realtime + imgproxy) : **Kubernetes Clever Cloud** pour héberger la stack de
services, avec les add-ons managés (PostgreSQL, Cellar) à côté.

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
