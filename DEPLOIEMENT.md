# Déploiement sur Supabase Cloud

Compter 30 à 45 minutes la première fois. Le plan gratuit suffit.

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

```bash
npm install -g supabase
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

**SQL Editor** → `scripts/post-deploiement.sql`, en remplaçant `<PROJECT_REF>`
et `<SERVICE_ROLE_KEY>`. Ça branche le job `pg_cron` sur l'Edge Function de
rappel et pointe le trigger antivirus vers `document-scan`.

Puis **Authentication → Hooks** → activer *Custom Access Token* et sélectionner
`auth_hooks.custom_access_token`. Sans ça, les claims `role_metier`,
`praticien_id` et `patient_id` sont absents du JWT et la moitié des policies RLS
renvoie zéro ligne.

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

Ces trois fichiers sont la matière réelle du plan de migration : c'est là qu'on
voit ce qui se restaure tel quel sur un PostgreSQL managé et ce qui coince.
