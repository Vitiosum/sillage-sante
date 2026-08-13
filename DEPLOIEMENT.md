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

`pgsodium` peut échouer : il est
[déprécié](https://supabase.com/docs/guides/database/extensions/pgsodium) et
n'est plus provisionné sur les nouveaux projets. Ce n'est pas bloquant — les
migrations le détectent et le chiffrement du NIR bascule sur `lib/chiffrement.ts`.
Note-le, c'est justement un des points que le plan de migration doit relever.

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

Attendu : environ 45 policies, 3 buckets, 3 tables publiées, 4 jobs cron si
`pg_cron` est actif.

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
