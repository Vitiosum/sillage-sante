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
| 8 | Le SQL Editor exécute le batch **en une transaction** : l'absence de `supabase_functions` annulait les étapes 1 à 5 avec elle | tout passé en migration sauf la pose du secret ; l'étape webhook est gardée |
| 9 | `seed.sql` n'est pas joué par `db push` (sortie : `"seeds":[]`) — le cabinet de démo n'existait jamais | `--include-seed`, puis migration de géolocalisation rejouée après |
| 10 | Les deux bugs de `rappel-rdv` (voir plus bas) | corrigés, la fonction rend `200` |

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

## Mesuré sous charge — les chiffres de la fenêtre de bascule

20 000 consultations, chacune avec un embedding `vector(1536)`, 500 patients,
5 objets dans les buckets, 6 sessions et 1 facteur TOTP. Base : **363 Mo**.

### Ce qui coûte, et combien

| Opération | Mesure |
|---|---|
| `pg_dump --schema-only` | 7,0 s → 73 Ko |
| `pg_dump --data-only` (20 k vecteurs) | **1 min 42 s → 324 Mo** |
| `pg_dump` de `auth` + `storage` | 6,9 s → 143 Ko |
| Reconstruction de l'index `ivfflat` | **45,5 s**, 158 Mo |
| Insertion de 20 000 rendez-vous | 2,1 s |
| Insertion de 20 000 consultations | 3,9 s |

**Le dump texte double le volume des vecteurs** : 324 Mo de SQL pour 175 Mo
de table, parce que `pg_dump` écrit `[0.123,0.456,…]` au lieu du binaire
`float4`. À 200 000 vecteurs, compter ~3,2 Go et ~17 min rien que pour le
dump — avant tout transfert et tout `restore`.

### Quatre plafonds rencontrés, tous silencieux jusqu'à ce qu'on les touche

1. **`maintenance_work_mem` = 32 Mo sur le gabarit NANO.** L'index `ivfflat`
   de 20 000 vecteurs en réclame 65 : `ERROR: memory required is 65 MB`.
   **Sur ce gabarit, l'index est irreconstructible** — donc `VACUUM FULL` sur
   la table l'est aussi, puisqu'il reconstruit les index. Il faut un `SET
   maintenance_work_mem` dans la session… et le pooler **filtre `PGOPTIONS`**,
   donc la variable doit être posée par `SET`, pas au démarrage de la
   connexion. Deux pièges enchaînés.
2. **`statement_timeout` = 2 min.** Toute opération de masse doit être
   découpée en lots. Un `UPDATE` sur 20 000 lignes ne passe pas d'un bloc.
3. **Plan gratuit = 500 Mo.** Atteint en cours de route à cause du point
   suivant.
4. **Le bloat MVCC des `UPDATE`.** Remplir les embeddings a produit 12 000
   tuples morts et fait passer le TOAST de 168 à 329 Mo. Un `UPDATE` de masse
   coûte transitoirement le double de l'espace final.

### Le journal d'audit pèse plus lourd que les données qu'il trace

`audit.journal_acces` est monté à **268 Mo pour 40 001 lignes**, soit 6,3 Ko
en moyenne : le trigger stocke la ligne complète en JSONB dans `apres`,
**embedding de 1536 dimensions inclus**. Chaque vecteur est donc stocké deux
fois — une fois dans la table, une fois dans son audit.

Et le job de purge ne supprime que ce qui a plus de **trois ans** :

```sql
delete from audit.journal_acces where horodatage < now() - interval '3 years';
```

Sur un déploiement neuf il ne se déclenche jamais. Le journal croît sans
borne, plus vite que la donnée. C'est un sujet de conception, pas seulement
de migration — mais il change le dimensionnement de la cible.

---

## Trouvé en exécutant, pas en lisant

L'analyse statique n'a rien vu de ce qui suit. Il a fallu invoquer les
fonctions et ouvrir une connexion `psql` pour que ça sorte. C'est l'argument
central de la démarche : **sur cette surface, rien ne se déduit.**

| Constat | Comment il est sorti |
|---|---|
| **`rappel-rdv` : `.schema('medical')` posé en fin de chaîne.** Sur un `PostgrestFilterBuilder`, qui n'a pas cette méthode → TypeError, HTTP 500. Les quatre autres fonctions utilisent la forme correcte. | `curl` sur la fonction |
| **`rappel-rdv` : `creneau` est un `tstzrange`**, pas un timestamp — c'est la colonne qui porte la contrainte d'exclusion `gist`. Le `.lte()` rendait `malformed range literal` : cette requête n'a jamais pu fonctionner. | idem, après correction du premier bug |
| **`postgres` porte `BYPASSRLS`** sur Supabase Cloud, ce qui prime sur `force row level security`. Un script d'insertion qui marche ici échouera sur un PostgreSQL managé où le propriétaire ne l'a pas. | insertion dans `medical.consultations` |
| **`service_role` n'a aucun droit de lecture sur `auth.users`** malgré `BYPASSRLS`. Le contourner par `set role service_role` ne marche pas. | même insertion |
| **La connexion directe est IPv6 par défaut.** Sur un réseau IPv4 il faut le Session pooler (`aws-1-eu-west-1.pooler.supabase.com`) ou l'add-on IPv4 payant. | panneau Connect |
| **`diagnostic_cim10` est un tableau**, pas un texte. | insertion du compte rendu |
| **`supabase_functions.http_request()` ne déclare aucun argument** : c'est une fonction *trigger*, ses cinq paramètres passent par `TG_ARGV`. | relevé après installation du module |
| **Le rôle métier n'est jamais posé.** L'API Admin de GoTrue insère la ligne dans `auth.users` **puis** met à jour `raw_app_meta_data`. Le trigger `AFTER INSERT` s'exécute avant, lit `NULL`, retombe sur `'patient'`. Les trois comptes ressortaient en `role_metier='patient'` alors qu'`auth.users` portait bien `praticien` et `secretariat`. Aucune erreur. Et le trigger n'est pas rejoué sur `UPDATE`, donc l'étape 7 de DEPLOIEMENT.md ne répare rien. | harnais de recette RLS |
| **Les buckets filtrent les types MIME** (`allowed_mime_types`) : un dépôt non conforme est refusé en 415 même avec `service_role`. Cellar ne filtre pas — la contrainte est à reproduire côté application. | dépôt d'objets |

### Le harnais de recette

`scripts/recette-rls.py` interroge PostgREST sous chaque identité et rend une
matrice ressource × identité. **C'est le test de recette de la migration** :
on le rejoue tel quel sur Clever Cloud, et une matrice identique vaut preuve
de reprise fidèle.

Il a immédiatement rendu mesurable ce que l'audit ne faisait que supposer :
une fois `role_metier` réparé et le praticien passé en `aal2`, le secrétariat
voit toujours **0 patient et 0 rendez-vous**. Les constats n°3 et n°23 ne sont
plus des hypothèses.

Prérequis : `scripts/sessions-mfa.py`, qui ouvre de vraies sessions via
`generate_link` + `verify` — sans jamais créer ni manipuler de mot de passe —
et enrôle un facteur TOTP pour atteindre `aal2`, sans quoi
`medical.mfa_verifiee()` verrouille tout le parcours praticien.

Deux choix de conception le rendent rejouable des mois plus tard :

- **il renouvelle les jetons expirés** avant d'interroger. `jwt_expiry` vaut
  1 h ; sans ça, toute la matrice tomberait en `PGRST303` et ressemblerait à
  une régression massive alors que le jeton est simplement périmé ;
- **les attendus sont exprimés en isolation** (`0`, `>0`), pas en valeurs
  absolues. Le corpus varie selon qu'on a chargé le volume ou non, les règles
  d'accès non. C'est ce qui permet de comparer source et cible sans réécrire
  le test.

Il utilise `Prefer: count=exact` : compter les lignes ramenées afficherait le
plafond de pagination, pas la vérité — c'est ce qui faisait lire « 1000
rendez-vous » là où il y en a 20 003.

### Une asymétrie du modèle, visible seulement sous charge

Le praticien voit **20 003 rendez-vous mais une seule consultation**. Ce n'est
pas un bug : la policy des rendez-vous s'appuie sur `praticien_id` seul, celle
des consultations exige en plus `a_une_prise_en_charge(patient_id)`. Les 500
patients de volume n'ont pas de prise en charge.

Conséquence pour la cible : l'agenda fuit plus largement que le dossier
médical. À vérifier après migration — c'est typiquement le genre d'écart
qu'une reprise « fidèle » peut introduire sans que personne ne le voie.

### Lire la base sans Docker ni mot de passe

Tant que `SUPABASE_DB_URL` n'était pas renseignée, aucun accès SQL n'était
possible : `supabase db dump` lance `pg_dump` dans un conteneur, et Docker
était absent. Contournement utilisé — une migration jetable qui `raise
exception` : le message remonte dans la sortie de `db push`, la transaction
est annulée, rien n'est écrit ni enregistré dans `schema_migrations`.

C'est ce qui a permis de relever les extensions, les policies, les jobs cron
et les triggers avant d'avoir la moindre connexion directe.

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
| ~~`..._webhooks_et_files.sql:12-32`~~ | ~~Schéma `supabase_functions` absent~~ — **résolu** : module installé, trigger `rdv_confirme_webhook` posé et déclenché avec succès. |
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
