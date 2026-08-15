# Sortir de Supabase, mesuré — Supabase to Clever Cloud

Une application Supabase complète, réellement déployée, réellement mesurée,
puis analysée pour une reprise ailleurs. **Tous les chiffres publiés ici
viennent de cette exécution, pas d'une estimation.**

*A complete Supabase application, actually deployed, actually measured, then
analysed for a move elsewhere. **Every figure here comes from that run, not
from an estimate.***

---

## 🇬🇧 In English

| Document | What it answers |
|---|---|
| **[MIGRATING-FROM-SUPABASE.md](MIGRATING-FROM-SUPABASE.md)** | What carries over, what has **no equivalent**, what the cutover costs in time, and how to prove the migration is faithful. **Start here.** |
| **[LANDING-ON-CLEVER-CLOUD.md](LANDING-ON-CLEVER-CLOUD.md)** | The concrete path: target architecture, commands, component-by-component mapping, and how to price it. |

In one sentence: **you don't migrate Supabase, you migrate your application.**
Five components have no equivalent anywhere else, and a standard managed
database cannot host the Supabase stack. The simplest path is not to rebuild it
— it is to replace it with an ordinary backend.

*French health data hosting (HDS) is covered in French only, its subject being
French law.*

---

## 🇫🇷 Vous cherchez à migrer depuis Supabase

| Document | Ce qu'il répond |
|---|---|
| **[MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md)** | Ce qui se reprend tel quel, ce qui n'a **aucun équivalent**, ce que coûte la bascule en temps, et comment prouver que la reprise est fidèle. **Commencez ici.** |
| **[ATTERRIR-SUR-CLEVER-CLOUD.md](ATTERRIR-SUR-CLEVER-CLOUD.md)** | Le chemin concret : l'architecture cible, les commandes, et la correspondance composant par composant — vos policies RLS, vos secrets, vos tâches planifiées, vos buckets. |
| [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md) | Le supplément si vous hébergez des données de santé : ce que le référentiel impose réellement — et les quatre idées reçues qui font dimensionner à côté. |

En une phrase : **on ne migre pas Supabase, on migre son application.** Cinq
composants n'ont aucun équivalent ailleurs, et une base managée standard ne
peut pas héberger la stack Supabase. Le chemin le plus simple n'est pas de la
reconstituer — c'est de la remplacer par un backend ordinaire.

## Vous voulez l'application de référence

C'est le code de ce dépôt : une plateforme de téléconsultation sur **Supabase
Cloud**, Next.js 14 côté front, PostgREST appelé directement depuis le
navigateur, aucun backend intermédiaire.

Elle est **volontairement dense** — PostgREST, GoTrue, Storage, Realtime, Edge
Functions, `pg_cron`, `pg_net`, Vault, `pgmq`, PostGIS, pgvector — pour que la
démonstration couvre une large surface. La vôtre en utilise probablement moins.

| Document | Pour |
|---|---|
| [DEPLOIEMENT.md](DEPLOIEMENT.md) | déployer l'application sur un projet Supabase neuf |
| [CONSTATS-DEPLOIEMENT.md](CONSTATS-DEPLOIEMENT.md) | ce que le déploiement réel a révélé, et que la lecture du code ne montrait pas |
| [PROCEDURE-MIGRATION.md](PROCEDURE-MIGRATION.md) | la méthode complète, déroulée sur ce cas |
| [CLAUDE.md](CLAUDE.md) | cartographie composant par composant et règles de travail |

> Aucune donnée réelle, aucun secret valide. Le dépôt sert aussi de cas de test
> à un exercice de migration : certaines difficultés y sont **volontaires**.

## Le produit en une page

Trois rôles métier, un seul socle :

- **Patient** — prend rendez-vous, dépose ses documents, échange avec son
  praticien, consulte ses comptes rendus une fois clôturés.
- **Praticien** — gère son agenda, rédige les comptes rendus, prescrit,
  recherche dans son historique. Second facteur exigé pour tout contenu médical.
- **Secrétariat** — voit l'agenda et l'identité des patients du cabinet,
  jamais le contenu médical.

La table `medical.prises_en_charge` est le pivot : c'est elle qui détermine
quel praticien accède à quel dossier, et toutes les policies RLS en dérivent.

## Démarrer

```bash
cp .env.example .env.local     # renseigner les clés du projet Supabase
npm install
npx supabase link --project-ref <votre-ref>
npx supabase db push           # applique les 9 migrations
npx supabase functions deploy  # déploie les 4 Edge Functions
npm run dev
```

Les extensions `pgsodium`, `pg_cron`, `pg_net`, `pgjwt`, `vector` et
`supabase_vault` doivent être activées sur le projet (Database → Extensions).

## Architecture

```
Navigateur (Next.js)
   │
   ├── @supabase/supabase-js ──► PostgREST      (tables, vues, RPC, RLS)
   │                          ├► GoTrue         (magic link, OIDC, MFA)
   │                          ├► Storage API    (3 buckets)
   │                          ├► Realtime       (postgres_changes, broadcast, presence)
   │                          └► Edge Functions (4 fonctions Deno)
   │
   └── Server Components ──► PostgREST via cookies (@supabase/ssr)

PostgreSQL
   ├── schéma medical  → exposé via PostgREST
   ├── schéma audit    → jamais exposé
   ├── schéma auth_hooks → appelé par GoTrue
   ├── pg_cron → 4 tâches planifiées
   └── pg_net  → appel sortant vers l'antivirus à chaque dépôt
```

## Ce que le dépôt contient

### Base de données — `supabase/migrations/`

| Fichier | Contenu |
|---|---|
| `..._extensions.sql` | 13 extensions, dont 7 propres à l'image Supabase |
| `..._roles_et_schemas.sql` | 3 schémas métier, rôles `anon` / `authenticated` / `service_role` / `batch_runner`, GRANTs par défaut |
| `..._tables.sql` | 14 tables, 4 types énumérés, contrainte d'exclusion `gist` sur l'agenda, colonne chiffrée `pgsodium` (NIR), index `ivfflat` |
| `..._fonctions_triggers.sql` | 5 helpers d'autorisation, trigger `on auth.users`, journal d'audit, 4 RPC exposées, 1 vue `security_invoker` |
| `..._rls.sql` | 34 policies, `force row level security` sur les tables sensibles |
| `..._auth_hook_claims.sql` | Hook GoTrue `custom_access_token` : claims métier dans le JWT |
| `..._storage.sql` | 3 buckets, 9 policies `storage.objects` |
| `..._realtime.sql` | Publication logique, `replica identity full`, policies sur `realtime.messages` |
| `..._vault_cron_net.sql` | 3 secrets Vault, trigger `pg_net`, 4 jobs `pg_cron` |
| `..._geolocalisation.sql` | PostGIS, `geography(point)` sur les cabinets, index gist, RPC de recherche par rayon, zones d'intervention en polygone |
| `..._webhooks_et_files.sql` | Database Webhook (`supabase_functions.http_request`), 3 files `pgmq`, trigger d'empilement |
| `..._storage_avance.sql` | Bucket `imagerie` 5 Go, suivi des téléversements TUS, vue de volumétrie |

### Edge Functions — `supabase/functions/`

- `rappel-rdv` — déclenchée par `pg_cron`, envoie les rappels J-1 (`verify_jwt = false`)
- `ordonnance-pdf` — génère le PDF, le dépose sur le Storage, calcule l'empreinte
- `document-scan` — webhook antivirus, authentifié par HMAC
- `recherche-semantique` — embedding OpenAI puis `pgvector` via RPC
- `traiter-files` — consomme les files `pgmq`, recalcule les embeddings

### Front — `app/`, `lib/`

- `lib/supabase/{client,server,admin}.ts` — les trois niveaux de clé
- `middleware.ts` — rafraîchissement de session + garde `aal2` sur `/dossiers`
- `app/dossiers/[id]/messagerie.tsx` — abonnement `postgres_changes`
- `app/teleconsultation/[id]/page.tsx` — Presence + Broadcast (signalisation WebRTC)
- `app/documents/page.tsx` — chiffrement AES-GCM navigateur avant upload, URL signée
- `lib/chiffrement.ts` — clé applicative issue de l'environnement
- `lib/storage.ts` — transformation d'image à la volée, upload reprenable TUS
- `app/recherche/page.tsx` — RPC PostGIS `st_dwithin` depuis la géoloc navigateur

## Points volontairement difficiles

Ils sont là pour être trouvés. Un plan de migration qui ne les mentionne pas est
incomplet.

1. **`pgsodium` / TCE sur `patients.nir_chiffre`** — le `security label` ne se
   restaure pas tel quel via un `pg_dump/pg_restore` classique. Arbitrage à
   poser : chiffrement applicatif à la place, ou demande d'activation.
2. **`supabase_vault`** — trois secrets y sont stockés et lus par un trigger.
   S'ils ne sont plus dans le Vault, il faut décider où ils vivent.
3. **`pg_cron` + `pg_net`** — quatre jobs et un appel sortant en trigger. Si les
   deux extensions ne sont pas disponibles, la logique doit sortir de la base.
4. **Hook GoTrue `custom_access_token`** — déclaré dans `config.toml` en
   `pg-functions://`. À retranscrire en variable d'environnement GoTrue, et le
   rôle `supabase_auth_admin` doit exister avec les bons GRANTs.
5. **`medical.mfa_verifiee()`** — les policies lisent le claim `aal`. Vérifier
   que le GoTrue redéployé émet bien ce claim.
6. **Realtime** — publication logique, `replica identity full`, et des policies
   sur `realtime.messages` pour Broadcast/Presence. C'est le composant le plus
   coûteux à reprendre.
7. **`pg_graphql`** — l'extension est activée mais aucun appel `/graphql/v1` n'est
   fait dans le code. Le plan doit le dire plutôt que de la porter par réflexe.
8. **`vector` + index `ivfflat`** — dimension 1536, réindexation planifiée.
9. **Rôles PostgREST** — `authenticator` doit endosser les trois rôles, et
   `service_role` a `BYPASSRLS`. Sur un PostgreSQL managé, ces attributions ne
   sont pas acquises.
10. **Schéma `audit` non exposé** — il est volontairement absent de
    `PGRST_DB_SCHEMAS`. La config PostgREST cible doit reproduire ce périmètre.
11. **`app/api-recherche.ts`** — appelle `supabase.functions.invoke()`, donc une
    URL de fonction à réécrire, pas seulement l'URL de base.
12. **`supabase_functions.http_request`** — les Database Webhooks du dashboard
    sont une surcouche maison à `pg_net`, absente d'un PostgreSQL standard. Le
    trigger `rdv_confirme_webhook` en dépend.
13. **`pgmq`** — trois files d'attente et un trigger d'empilement. L'extension
    existe en open source, mais l'intégration « Queues » du dashboard non.
14. **PostGIS** — extension lourde, à confirmer sur la plateforme cible.
15. **Transformation d'image Storage** — `getPublicUrl(..., { transform })`
    s'appuie sur imgproxy, un conteneur de plus à déployer.
16. **Upload reprenable TUS** — endpoint `/storage/v1/upload/resumable`, taille
    de segment imposée à 6 Mio. À vérifier derrière un autre load balancer.
17. **Auth anonyme + liaison d'identités** — la pré-inscription crée un
    utilisateur anonyme fusionné ensuite. Comportement GoTrue à valider.
18. **Trois clés distinctes** — `anon` dans le navigateur, `service_role` côté
    serveur et dans deux Edge Functions, `SUPABASE_JWT_SECRET` pour les signer.
    Toutes à régénérer de façon cohérente.

## Ce qu'il n'y a pas

Volontairement, pour que le périmètre reste lisible : pas de paiement, pas de
multi-tenant, pas d'i18n, pas de tests. Le front est fonctionnel mais minimal —
la valeur du dépôt est dans la surface Supabase, pas dans l'interface.
