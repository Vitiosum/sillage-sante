# Constats de déploiement — 13 août 2026

Ce que le déploiement réel de la source sur Supabase Cloud a révélé.
Projet `hdhmnoliwhsqiuawqrnp`, PostgreSQL 17.6, CLI 2.114.0, plan gratuit.

93 risques ont été instruits, chacun soumis à une réfutation adverse. 68 sont
tombés. Les 25 survivants sont ci-dessous, recroisés avec l'état réel de la
base — ce recroisement en a invalidé deux de plus.

**Ce document n'est pas une liste de bugs à corriger.** Le dépôt est un cas de
test : ces constats sont la matière du plan de migration. Ce qui est corrigé
l'est parce que le déploiement le réclamait ; le reste est documenté et laissé
en place.

---

## Corrigé pendant le déploiement

| # | Constat | Correctif |
|---|---|---|
| 1 | `templates/magic_link.html` et `invite.html` référencés par `config.toml` mais absents du dépôt : **toute** commande CLI échouait au chargement de la config | gabarits écrits |
| 2 | Schéma `medical` non exposé à PostgREST. `db push` ne pousse pas `config.toml` → tout appel du front renvoie `PGRST106 The schema must be one of the following: public, graphql_public` | `supabase config push` |
| 3 | Le hook `custom_access_token` n'était activable qu'à la main dans le dashboard | `config push` l'applique, ainsi que l'auth anonyme, la liaison d'identités et la MFA |
| 4 | **`supabase_auth_admin` sans `USAGE` sur `medical`** → `permission denied`, GoTrue rend HTTP 500 à chaque émission de jeton : plus aucune connexion possible | migration `20260813120000_hook_grants_medical.sql` |
| 5 | Policy de lecture du hook créée sur `medical.profils` seulement → `praticien_id` et `patient_id` absents du JWT, en silence | idem, policies ajoutées sur `praticiens` et `patients` |
| 6 | Clé `service_role` à coller dans `post-deploiement.sql`, fichier suivi par git, dépôt public, workflow `git add .` documenté | `scripts/post-deploiement.sh` génère une copie ignorée par git |
| 7 | Compteurs de vérification faux (« ~45 policies, 3 buckets, 4 jobs cron ») : aucun état atteignable | relevés réels dans DEPLOIEMENT.md |

Le correctif n°4 mérite un mot : le bug préexistait, mais la procédure demandait
d'activer le hook à la main — n'importe qui l'aurait déclenché. La fonction est
`stable` et non `security definer`, donc elle s'exécute avec les droits de
`supabase_auth_admin`, qui doit tout posséder explicitement. C'est exactement le
genre de dépendance de droits invisible tant qu'on n'exécute pas.

---

## Invalidé par l'état réel de la base

Deux constats confirmés par l'analyse, démentis par le relevé :

| Constat | Réalité |
|---|---|
| « `pg_net` demandé dans le schéma `extensions`, donc jamais installé, trigger antivirus mort » | **`pg_net` 0.20.4 installé** |
| « `pgjwt` n'existe plus sur les projets créés en 2026 : bruit permanent » | **`pgjwt` 0.2.0 installé** |

Et la documentation elle-même se trompait :

| DEPLOIEMENT.md disait | Réalité |
|---|---|
| « `pgsodium` est déprécié et n'est plus provisionné » | **`pgsodium` 3.1.8 installé** |

Conséquence pour la démo : le chiffrement TCE de `patients.nir_chiffre` est
**actif**, pas théorique. Le point dur n°1 du README se démontre en conditions
réelles — on migre un `security label` qui existe et qui ne se restaure pas par
`pg_restore`, pas une hypothèse.

---

## Ouvert — sécurité

**Le canal de téléconsultation est public.** Les deux policies sur
`realtime.messages` (`20260114090700_realtime.sql:40-62`) existent en base mais
ne sont jamais évaluées : le client ouvre le canal sans `config.private = true`
(`app/teleconsultation/[id]/page.tsx`). N'importe quel porteur de la clé `anon`
qui connaît l'UUID d'un rendez-vous rejoint la salle. Correctif : passer le
canal en privé côté client — la policy seule ne protège rien.

**`public.volumetrie_stockage`** (`..._storage_avance.sql:61-71`) est en
`security_invoker` et exposée à `authenticated` : elle renvoie zéro ligne à ses
utilisateurs. Restreindre à `service_role` plutôt que de retirer le
`security_invoker`.

---

## Ouvert — fonctionnalités mortes sans erreur

Ces points ne cassent rien visiblement. Ils rendent une fonctionnalité inerte,
ce qui est pire à diagnostiquer.

| Fichier | Constat |
|---|---|
| `..._rls.sql:69-82`, `:103-123` | **Le secrétariat n'a aucun accès réel.** La policy joint `medical.praticiens.cabinet_id` à un `profil_id` de secrétaire — le modèle n'a pas de lien secrétaire↔cabinet. Et les cinq policies de `rendez_vous` ne testent que patient et praticien. Le troisième rôle métier annoncé par le README est mort à la livraison. Correctif : `medical.profils.cabinet_id` + un helper `medical.cabinet_courant()`. |
| `app/recherche/page.tsx:29` | La RPC `praticiens_a_proximite` est créée dans `public` mais appelée avec un client forcé sur `medical` → `Could not find the function medical.praticiens_a_proximite`. La page `/recherche` est cassée en permanence. |
| `..._rls.sql:132-136` | `medical.mfa_verifiee()` échoue fermé : sans facteur TOTP enrôlé, le praticien voit une interface vide et un `42501` à l'écriture. À enrôler avant toute recette. |
| `..._webhooks_et_files.sql:12-32` | Le schéma `supabase_functions` n'existe pas tant que les Database Webhooks ne sont pas activés dans le dashboard → le trigger `rdv_confirme_webhook` n'est jamais créé. `db push` émet un `WARNING` et continue. |
| `..._storage_avance.sql:14-25` | `medical.televersements` est une table maison que rien n'alimente : le protocole TUS ne l'écrit jamais. `url_tus` reste `NULL`, les lignes s'accumulent en « en cours ». |
| `..._storage_avance.sql:9-12` | Bucket `imagerie` déclaré à 5 Gio. `storage.buckets.file_size_limit` est un `bigint` sans contrainte, l'insert passe — mais la limite globale du projet plafonne, et l'upload réel rend `413 Payload too large`. |
| `..._storage_avance.sql:37` vs `:56` | Le suivi de téléversement accepte un dépôt patient que la policy Storage refuse ensuite : ligne de suivi orpheline. |
| `..._roles_et_schemas.sql:29-39` | Le rôle `batch_runner` est créé `NOLOGIN`, sans mot de passe, sans `GRANT … TO`, absent de `authenticator` : personne ne peut l'endosser. |

---

## Ouvert — pièges d'exploitation

**`seed.sql` n'est pas exécuté par `db push`.** Vérifié : la sortie rend
`"seeds":[]`. Le cabinet `11111111-1111-1111-1111-111111111111` n'existe donc
jamais, et l'étape 7 de DEPLOIEMENT.md échoue sur une violation de clé
étrangère. Attention en corrigeant : `--include-seed` ne doit pas remplacer
`--include-all`, sous peine que les migrations de janvier soient ignorées.

**`..._fonctions_triggers.sql:134`** — `current_setting('request.jwt.claims',
true)::jsonb` sans `nullif` : dès que le GUC vaut la chaîne vide, toute écriture
tracée casse sur `invalid input syntax for type json`. Correctif d'une ligne :
`nullif(current_setting('request.jwt.claims', true), '')::jsonb`, ou plus court
`auth.jwt() ->> 'role'`.

**`..._storage_avance.sql:49,57`** — `((storage.foldername(name))[1])::uuid` :
un seul objet dont le premier dossier n'est pas un UUID fait planter *toute*
lecture du bucket avec `22P02 invalid input syntax`.

**Les `raise warning` passent inaperçus** (`..._realtime.sql:25,66`). Le push
affiche `Finished`, la migration est enregistrée dans `schema_migrations`, et un
nouveau `db push` ne la rejouera jamais. Ce qui a échoué reste échoué en
silence. C'est la contrepartie des migrations « tolérantes ».

**Comptage `cron` incohérent** : le message annonce 4 tâches, le bloc en crée 3,
le total après `post-deploiement.sql` est 5. Relevé réel après `db push` : 3.

**`post-deploiement.sql`** place ses vérifications avant la dernière création de
job, et le SQL Editor n'affiche que le résultat du dernier `select` d'un batch :
deux des trois contrôles sont invisibles.

---

## Méthode

L'analyse a tourné en 100 agents parallèles : six lecteurs spécialisés par lot
de migrations, puis un réfutateur par risque, chacun chargé de **démolir** le
constat plutôt que de le confirmer — code et documentation officielle à l'appui,
`refute = true` par défaut. 68 des 93 risques n'ont pas survécu.

Le recroisement final avec l'état réel de la base en a écarté deux de plus. La
leçon vaut pour la phase Clever Cloud : sur cette surface, **rien ne se déduit,
tout se relève**.
