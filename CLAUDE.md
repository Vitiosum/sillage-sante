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

### Phase 1 — Faire vivre la source (Supabase Cloud)

Objectif : un système réellement déployé, avec des données, pour produire les
dumps qui serviront de matière à la migration. Procédure complète dans
[DEPLOIEMENT.md](DEPLOIEMENT.md).

```bash
supabase link --project-ref <ref>
supabase db push
./scripts/deployer.sh <ref>
```

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
