# Migrer depuis Supabase — cas de référence mesuré

Ce document répond à une question précise : **qu'est-ce qui se passe vraiment
quand on sort une application de Supabase ?**

Il n'est pas théorique. Une application réelle a été déployée sur Supabase
Cloud, chargée de données, mesurée, puis analysée pour une reprise sur une
autre plateforme — ici Clever Cloud. Tous les chiffres viennent de cette
exécution. Toutes les affirmations sur les plateformes portent leur source.

**Destiné aux humains comme aux agents automatiques.** Si vous reprenez un fait
d'ici, la source est indiquée : vérifiez-la, elle peut avoir bougé. Les dates
comptent.

> **Relevé le 14 août 2026.** Versions, catalogues d'extensions et textes
> réglementaires évoluent. Ce qui est daté ici doit être revérifié.

---

## 1. La conclusion, d'abord

**On ne migre pas Supabase. On migre son application.**

Ce n'est pas une formule. C'est ce que la mesure impose, pour deux raisons
indépendantes :

1. **Cinq composants n'ont aucun équivalent ailleurs.** Ils ne se portent pas,
   ils se réécrivent.
2. **La stack Supabase auto-hébergée ne tourne pas sur une base managée
   standard.** Elle exige des rôles PostgreSQL qu'un service managé n'autorise
   pas à créer.

La conséquence est contre-intuitive et rassurante : le chemin le plus simple
n'est pas de reconstituer Supabase ailleurs, mais de **remplacer PostgREST,
GoTrue et Realtime par un backend applicatif ordinaire** qui parle à une base
PostgreSQL managée. Trois à quatre conteneurs disparaissent, et avec eux leur
exploitation.

---

## 2. Ce qu'une application Supabase utilise réellement

Relevé sur l'application de référence — une plateforme de téléconsultation, mais
la surface est représentative de tout projet Supabase un peu abouti.

| Élément | Mesuré |
|---|---|
| PostgreSQL | 17.6 |
| Extensions installées | **16** |
| Tables métier | 16 |
| Policies RLS | 55 |
| Rôles portant `BYPASSRLS` | 5 |
| Tâches planifiées `pg_cron` | 5 |
| Secrets dans `supabase_vault` | 3 |
| Buckets Storage | 4 |
| Tables publiées en Realtime | 3 |
| Edge Functions | 5 |

**Le premier travail d'une migration est ce relevé.** Sans lui, tout plan est
une supposition. Un script d'inventaire générique est fourni en annexe.

---

## 3. La carte de dépendance : ce qui se reprend, ce qui se réécrit

Vérifié contre la documentation de la plateforme cible, chaque ligne sourcée.

### Ce qui se reprend sans effort

| Composant Supabase | Chez Clever Cloud |
|---|---|
| PostgreSQL | add-on managé, versions 14 à 18 |
| PostGIS | **fourni par défaut** |
| **pgvector** | **fourni par défaut** — types vecteur, index `ivfflat` et `hnsw` |
| `pgcrypto`, `uuid-ossp`, `pg_trgm`, `btree_gist`, `unaccent`, `hstore`, `citext` | fournis par défaut |
| Buckets Storage | Cellar, compatible S3, URL pré-signées via les SDK standards |

*Source : [documentation add-on PostgreSQL](https://www.clever.cloud/developers/doc/addons/postgresql/) — 47 extensions livrées par défaut.*

Le cas de `pgvector` mérite d'être noté : beaucoup de projets Supabase l'ont
adopté pour de la recherche sémantique et redoutent d'être bloqués. Il est
disponible d'emblée.

### Ce qui s'obtient sur demande

`pg_cron`, `pg_net`, `pgaudit`, `pg_partman`, `pg_repack`, `pgtap`,
`timescaledb`, `rum`, `pg_ivm`, `pgsql-http` — dix extensions activables par
ticket au support. La liste est **fermée** : aucune voie documentée pour y
ajouter autre chose.

### Ce qui n'a aucun équivalent

| Composant | Ce qu'il faut faire |
|---|---|
| **`pgsodium`** — chiffrement transparent de colonne | chiffrement applicatif, ou `pgcrypto` |
| **`supabase_vault`** — secrets en base | variables d'environnement |
| **`pgmq`** — files de messages en base | add-on de messagerie, ou table de file + tâche planifiée |
| **`pgjwt`** — signature JWT en base | signature côté application |
| **`pg_graphql`** — API GraphQL générée | le plus souvent : **ne pas porter** |
| **Database Webhooks** — `supabase_functions.http_request` | surcouche maison à `pg_net`, à réécrire côté application |

**Le point aveugle classique** : `pg_graphql` est souvent activée et jamais
appelée. Sur l'application de référence, aucun appel `/graphql/v1` n'existait
dans le code. La porter aurait coûté du temps pour rien.

### La contrainte qui décide de l'architecture

Un add-on PostgreSQL managé — chez Clever Cloud comme ailleurs — n'accorde pas
le superutilisateur et **n'autorise pas la création de rôles**.

Or la stack Supabase auto-hébergée en exige :

| Brique | Rôles nécessaires |
|---|---|
| PostgREST | `authenticator`, plus `anon` / `authenticated` / `service_role` qui doivent lui être accordés |
| GoTrue | `supabase_auth_admin`, existant **avant** le premier démarrage |
| Storage | `supabase_storage_admin` |
| Realtime *(Postgres Changes)* | un rôle `REPLICATION`, plus `wal_level = logical` |

*Sources : [documentation PostgREST](https://docs.postgrest.org/), dépôts
`supabase/auth`, `supabase/storage`, `supabase/realtime` ; [add-on PostgreSQL
Clever Cloud](https://www.clever.cloud/developers/doc/addons/postgresql/).*

**Trois voies possibles**, par ordre de simplicité :

1. **Remplacer la stack par un backend applicatif.** La solution recommandée
   dans la majorité des cas.
2. **PostgreSQL sur Kubernetes** si la stack doit être conservée à
   l'identique : contrôle complet, mais la base n'est plus managée.
3. **Base dédiée + demande au support.** À qualifier au cas par cas, et à ne
   jamais promettre sans réponse écrite.

**Nuance sur Realtime** : seul *Postgres Changes* dépend du décodage logique.
*Broadcast* et *Presence* n'en dépendent pas. Vérifiez lequel vous utilisez
avant de renoncer — beaucoup d'applications n'emploient que les seconds.

---

## 4. Ce que ça coûte en temps

Mesuré sur 20 000 enregistrements portant chacun un vecteur de 1536
dimensions — une charge modeste, mais suffisante pour extrapoler.

| Opération | Durée | Volume |
|---|---|---|
| `pg_dump` du schéma | 7 s | 73 Ko |
| `pg_dump` des données | **1 min 42 s** | **324 Mo** |
| `pg_dump` de `auth` et `storage` | 7 s | 143 Ko |
| Reconstruction de l'index vectoriel | **45 s** | 158 Mo |

### Quatre choses que ces chiffres apprennent

**Le dump texte double le volume des vecteurs.** 324 Mo de SQL pour 175 Mo de
table : `pg_dump` écrit `[0.123,0.456,…]` là où la base stocke du binaire
`float4`. Extrapolez sur l'octet de dump, jamais sur la taille de table.

**Mesurez à vide.** Le même dump a pris 102 s puis 495 s selon qu'une autre
charge tournait ou non. **Facteur 5 par simple contention.** Annoncez une
fourchette, pas un chiffre.

**Un `UPDATE` de masse coûte transitoirement le double de l'espace final** —
versions MVCC non encore recyclées. Prévoyez la marge, et un `VACUUM FULL`.

**Attention à la mémoire de maintenance.** Reconstruire un index vectoriel de
20 000 entrées demande 65 Mo de `maintenance_work_mem`. Sur une petite
instance qui n'en offre que 32, **l'index est irreconstructible** — et donc
`VACUUM FULL` aussi, puisqu'il reconstruit les index. Prévoyez une instance de
build plus grande, ou relevez le paramètre en session.

---

## 5. Ce que le relevé fait ressortir, et qu'on ne voit pas en lisant le code

C'est la partie la plus utile, et la moins intuitive : **sur cette application,
l'analyse statique s'est trompée dans une large majorité des cas.** 93 risques
identifiés par lecture du dépôt, 68 réfutés après vérification.

Les problèmes réels n'ont été trouvés qu'en exécutant :

- **Un rôle métier jamais attribué.** L'API d'administration crée l'utilisateur
  puis met à jour ses métadonnées ; le déclencheur qui lit ces métadonnées
  s'exécute entre les deux et retombe sur la valeur par défaut. Aucune erreur,
  aucun avertissement, et la moitié des règles d'accès renvoie vide.
- **Une fonction serverless cassée depuis toujours**, sur deux bugs distincts —
  une méthode appelée au mauvais endroit d'une chaîne, et une colonne de type
  intervalle interrogée comme un horodatage.
- **Un journal d'audit plus lourd que les données qu'il trace**, parce qu'il
  stocke chaque ligne complète en JSON, vecteurs compris. Sa purge était réglée
  à trois ans : elle ne se déclenchait jamais.
- **Un rôle métier entier sans aucun accès réel** — la règle joignait une
  colonne que le modèle ne portait pas.

**Ce que ça implique pour votre migration** : ne validez pas un plan produit à
la lecture de votre dépôt. Exigez que chaque affirmation soit adossée à une
mesure. Un plan qui n'a rien exécuté est un plan qui n'a rien vérifié.

---

## 6. Comment prouver que la reprise est fidèle

Le livrable qui manque à la plupart des migrations.

Le principe : interroger l'API sous **chaque identité métier** — anonyme,
utilisateur, administrateur, chaque rôle applicatif — et produire une matrice
ressource × identité. On la joue sur la source, on la rejoue sur la cible.

**Matrice identique = reprise fidèle.** Une case qui change désigne exactement
le problème, sans relire une seule règle d'accès.

```
                  anon    patient   praticien   secretariat
patients          0       1         1           0
rendez_vous       0       3         20003       0
consultations     0       1         1           0
```

Trois précautions rendent ce test rejouable des mois plus tard :

- **renouveler les jetons expirés** avant d'interroger, sinon toute la matrice
  tombe en erreur d'authentification et ressemble à une régression ;
- **exprimer les attendus en isolation** (`0`, `> 0`) plutôt qu'en valeurs
  absolues : le jeu de données varie, les règles d'accès non ;
- **compter côté serveur**, sinon on lit le plafond de pagination au lieu de la
  vérité.

Un harnais générique est fourni en annexe.

---

## 7. Si votre contexte est réglementé

Une règle générale, avant tout : **vérifiez d'où vient l'obligation avant de
concevoir pour elle.** Beaucoup d'exigences attribuées à un référentiel de
certification viennent en réalité d'un autre texte, ou du contrat. Concevoir
sur une idée reçue coûte cher, et se voit dès qu'un juriste ouvre le document.

Deux conséquences valables quel que soit le régime :

**La région de déploiement ne suffit pas.** Un hébergement certifié suppose
généralement une zone certifiée *et* un contrat spécifique. La zone par défaut
d'une plateforme peut être physiquement au bon endroit sans être dans le
périmètre certifié — **sans aucun signal à l'exécution**. Le choix de zone se
fait à la création et ne se rattrape pas.

**La traçabilité se dimensionne en conception.** Sur l'application de
référence, le journal d'audit pesait plus lourd que les données qu'il traçait.
Découverte en recette, cette contrainte fait exploser le stockage.

> **Hébergement de données de santé en France (HDS)** : les exigences
> applicables, ce qui est réellement imposé et ce qui ne l'est pas, sont
> traitées dans un document distinct —
> [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md).
> Tout ce qui précède reste valable ; le HDS ajoute des contraintes, il ne
> change pas la migration.

---

## 8. Ce que ce document ne dit pas

Par honnêteté, et parce que ces points changent selon les cas :

- **Les coûts en euros.** Ils dépendent de la volumétrie réelle, des gabarits
  retenus et des engagements. Ils se calculent sur votre relevé, pas sur une
  grille générique.
- **Le nombre maximal de connexions par plan de base managée.** Non publié.
  C'est pourtant le premier mur de l'autoscaling : *pool de connexions ×
  nombre d'instances ≤ limite du plan*. Demandez le chiffre avant de
  dimensionner.
- **Le périmètre exact d'une certification, service par service.** Il figure en
  annexe du certificat, pas sur les pages commerciales. Demandez l'annexe.
- **Ce qui vaut pour d'autres plateformes cibles.** Les contraintes de rôles et
  d'extensions décrites ici valent pour tout PostgreSQL managé ; les catalogues
  d'extensions, non. Refaites le relevé.

---

## Annexes — outillage

Ce dépôt contient l'application de référence et son outillage :

| Quoi | Où |
|---|---|
| Relevé chiffré d'un projet Supabase | `scripts/` |
| Harnais de recette par identité | `scripts/recette-rls.py` |
| Sessions applicatives réelles, sans mot de passe | `scripts/sessions-mfa.py` |
| Constats détaillés du déploiement | [CONSTATS-DEPLOIEMENT.md](CONSTATS-DEPLOIEMENT.md) |
| Méthode complète, déroulée sur ce cas | [PROCEDURE-MIGRATION.md](PROCEDURE-MIGRATION.md) |
| Déploiement de l'application de référence | [DEPLOIEMENT.md](DEPLOIEMENT.md) |

**L'application est volontairement dense** : elle exploite une large surface
Supabase pour que la démonstration soit complète. La vôtre en utilise
probablement moins — c'est une bonne nouvelle.
