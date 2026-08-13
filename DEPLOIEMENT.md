# Déploiement sur Supabase Cloud

Compter 30 à 45 minutes la première fois. Le plan gratuit suffit.

> **Procédure vérifiée le 13 août 2026** contre la CLI 2.114.0 et un projet
> Cloud neuf en PostgreSQL 17. Les écarts constatés à l'exécution sont corrigés
> ci-dessous ; le récapitulatif est dans [CLAUDE.md](CLAUDE.md).

## 1. Créer le projet

<https://supabase.com/dashboard> → **New project**.

- Région : `eu-west-3` (Paris) — cohérent avec le scénario HDS de la démo.
- Note le **mot de passe base de données**, il n'est plus affiché ensuite.
- Le **project ref** est la chaîne dans l'URL du dashboard :
  `https://supabase.com/dashboard/project/<project-ref>`.

L'attente d'initialisation dure 2 à 3 minutes.

## 2. Activer les extensions

**Avant** toute migration. Deux options, la seconde est plus fiable :

- Dashboard → **Database → Extensions**, activer `pg_cron`, `pg_net`, `pgjwt`,
  `vector`, `pg_graphql`, `supabase_vault`.
- Ou : **SQL Editor → New query**, coller `scripts/prerequis.sql`, **Run**.

Pourquoi d'abord : activer `pg_cron` depuis une migration laisse les GRANTs
incomplets ([supabase/cli#1591](https://github.com/supabase/cli/issues/1591)),
et l'extension refuse tout schéma autre que `pg_catalog`
([supabase#27062](https://github.com/supabase/supabase/issues/27062)).

**Correction du 13 août 2026 :** `pgsodium` est annoncé
[déprécié](https://supabase.com/docs/guides/database/extensions/pgsodium), mais
sur un projet créé aujourd'hui il **s'installe toujours** — relevé en
`pgsodium 3.1.8`. Le chiffrement TCE de `patients.nir_chiffre` est donc bien
actif, et le point dur n°1 du README se démontre en vrai plutôt qu'en théorie.
La bascule vers `lib/chiffrement.ts` reste le plan de repli, pas l'état courant.

Même remarque pour `pgjwt` (0.2.0) et `pg_net` (0.20.4) : présents tous les
deux, contrairement à ce qu'on pouvait craindre sur un projet 2026.

## 3. Récupérer les clés

Dashboard → **Project Settings → API** :

| Valeur | Va dans |
|---|---|
| Project URL | `NEXT_PUBLIC_SUPABASE_URL` |
| `anon` / publishable | `NEXT_PUBLIC_SUPABASE_ANON_KEY` |
| `service_role` / secret | `SUPABASE_SERVICE_ROLE_KEY` |
| JWT Secret (onglet **JWT Keys**) | `SUPABASE_JWT_SECRET` |

```bash
cp .env.example .env.local   # puis renseigner
```

Génère aussi la clé de chiffrement documentaire :

```bash
openssl rand -base64 32   # → DOCUMENTS_ENCRYPTION_KEY
```

`BREVO_API_KEY` et `OPENAI_API_KEY` peuvent rester vides : les Edge Functions
concernées échoueront proprement, le reste fonctionne.

## 4. Installer la CLI et se connecter

`npm install -g supabase` n'est plus supporté : le paquet npm refuse
l'installation globale. Passer par Homebrew.

```bash
brew install supabase/tap/supabase
```

```bash
supabase login          # ouvre le navigateur
```

Doc : <https://supabase.com/docs/reference/cli/introduction>

## 5. Déployer

```bash
./scripts/deployer.sh <project-ref>
```

Le script enchaîne `link`, `db push`, `secrets set`, `functions deploy`.
Détail des commandes si tu préfères les passer une par une :

- [`supabase link`](https://supabase.com/docs/reference/cli/supabase-link)
- [`supabase db push`](https://supabase.com/docs/reference/cli/supabase-db-push)
- [`supabase secrets set`](https://supabase.com/docs/reference/cli/supabase-secrets-set)
- [`supabase functions deploy`](https://supabase.com/docs/reference/cli/supabase-functions-deploy)

Les migrations émettent des `WARNING` pour toute extension absente. Elles ne
s'arrêtent pas — lis-les, elles disent exactement ce qui n'a pas été installé.

## 6. Post-déploiement

**N'édite pas `scripts/post-deploiement.sql`** — il est suivi par git et le
dépôt est public. Y coller la clé `service_role`, qui contourne toutes les
policies RLS, la publierait au commit suivant.

```bash
./scripts/post-deploiement.sh <project-ref>
```

Le script lit `SUPABASE_SERVICE_ROLE_KEY` dans `.env.local` et génère
`scripts/post-deploiement.local.sql` (ignoré par git, permissions 600). Colle
**ce fichier-là** dans le SQL Editor, puis supprime-le. Ça branche le job
`pg_cron` sur l'Edge Function de rappel et pointe le trigger antivirus vers
`document-scan`.

### Le hook Custom Access Token n'est plus une étape manuelle

La procédure demandait d'aller dans **Authentication → Hooks**. Ce n'est plus
nécessaire : `supabase config push` applique `[auth.hook.custom_access_token]`
déclaré dans `config.toml`, ainsi que l'auth anonyme, la liaison manuelle
d'identités et la MFA.

```bash
NEXT_PUBLIC_SITE_URL=http://localhost:3000 supabase config push
```

La variable doit être exportée : **la CLI ne résout pas les `env()` absents**,
elle pousse la chaîne `"env(NEXT_PUBLIC_SITE_URL)"` telle quelle.

Le bloc `[auth]` part en un seul appel API — une seule sous-section invalide
fait échouer tout le reste, hook compris. Trois d'entre elles sont donc
neutralisées dans `config.toml`, avec la raison en commentaire :

| Section | Pourquoi |
|---|---|
| `[auth.email.template.*]` | le plan gratuit refuse toute modification de gabarit sans SMTP custom (`400`) |
| `[auth.email.smtp]` | `SMTP_USER` / `SMTP_PASS` non renseignés → poussés littéralement |
| `[auth.external.keycloak]`, `[auth.external.google]` | idem, pas de credentials OIDC sur ce déploiement |

Sans le hook, les claims `role_metier`, `praticien_id` et `patient_id` sont
absents du JWT et la moitié des policies RLS renvoie zéro ligne.

Doc : <https://supabase.com/docs/guides/auth/auth-hooks>

## 7. Comptes de test

Dashboard → **Authentication → Users → Add user**, ou en CLI :

```sql
-- SQL Editor : promouvoir un compte en praticien
update auth.users
   set raw_app_meta_data = raw_app_meta_data || '{"role_metier":"praticien"}'::jsonb
 where email = 'praticien@example.test';

-- puis créer sa fiche
insert into medical.praticiens (profil_id, cabinet_id, rpps, specialite)
select id, '11111111-1111-1111-1111-111111111111', '10001234567', 'Medecine generale'
from medical.profils where id = (select id from auth.users where email = 'praticien@example.test');
```

Crée aussi un compte patient (rôle par défaut) et une prise en charge entre les
deux, sinon toutes les policies renvoient vide et tu croiras à un bug.

## 8. Lancer le front

```bash
npm install
npm run dev
```

## Vérifier que tout est en place

```sql
select count(*) from pg_policies where schemaname in ('medical','storage','realtime');
select extname from pg_extension order by 1;
select jobname, schedule from cron.job;
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
select id, public from storage.buckets;
```

Relevé réellement le 13 août 2026 sur un projet neuf, après `db push` et avant
`post-deploiement.sql` :

| Contrôle | Attendu |
|---|---|
| Policies (`medical`, `storage`, `realtime`, `public`) | **55** |
| Buckets | **4** — `avatars` (2 Mio), `documents-medicaux` (50 Mio), `imagerie` (5 Gio), `ordonnances` (5 Mio) |
| Tables publiées en Realtime | **3** — `medical.messages`, `medical.notifications`, `medical.rendez_vous` |
| Jobs `cron` | **3** après `db push` (`purge-documents-infectes`, `purge-journal-acces`, `reindex-embeddings`), **5** après `post-deploiement.sql` |
| Extensions | **16** (liste ci-dessous) |

Les anciens chiffres de ce document (« environ 45 policies, 3 buckets, 4 jobs
cron ») ne correspondaient à aucun état atteignable et envoyaient chercher une
migration fantôme.

```text
btree_gist 1.7      pg_cron 1.6.4     pg_graphql 1.6.1   pg_net 0.20.4
pg_stat_statements  pg_trgm 1.6       pgcrypto 1.3       pgjwt 0.2.0
pgmq 1.5.1          pgsodium 3.1.8    plpgsql 1.0        postgis 3.3.7
supabase_vault 0.3.1  unaccent 1.1    uuid-ossp 1.1      vector 0.8.2
```

### Lire l'état de la base sans mot de passe

`supabase db dump` exige Docker et `psql` réclame le mot de passe. Pour un
simple relevé, une migration jetable qui `raise exception` fait l'affaire : le
message remonte dans la sortie de `db push` et la transaction est annulée, donc
rien n'est écrit ni enregistré dans `schema_migrations`.

```sql
do $$
declare v_ext text;
begin
  select string_agg(extname || ':' || extversion, ' ' order by extname) into v_ext from pg_extension;
  raise exception 'DIAGNOSTIC %', v_ext;
end $$;
```

Supprimer le fichier juste après lecture.

## Pour la suite : le dump à migrer

Une fois les comptes de test créés et deux ou trois consultations saisies :

```bash
supabase db dump -f dump_schema.sql
supabase db dump -f dump_data.sql --data-only
supabase db dump -f dump_auth.sql --schema auth,storage
```

**`supabase db dump` exige Docker** : la CLI lance `pg_dump` dans un conteneur,
même contre une base distante. Sans Docker Desktop, utiliser `pg_dump` en natif
avec la chaîne de connexion (`SUPABASE_DB_URL` de `.env.local`) :

```bash
pg_dump "$SUPABASE_DB_URL" --schema-only --schema=medical,audit,auth_hooks -f dump_schema.sql
```

Les trois fichiers sont couverts par `.gitignore` (`dump_*.sql`) : ils
contiennent des données et les secrets du Vault.

Ces trois fichiers sont la matière réelle du plan de migration : c'est là qu'on
voit ce qui se restaure tel quel sur un PostgreSQL managé et ce qui coince.
