# Procédure de migration, appliquée à ce cas

Ce document est le **cas travaillé** de la méthode générique, disponible comme
skill réutilisable sous `~/.claude/skills/migration-supabase-clever/`.

Ici, la méthode n'est pas exposée dans l'abstrait : elle est déroulée sur
Sillage Santé, avec les chiffres réellement mesurés. C'est ce qui se montre à
un client — une méthode illustrée pèse plus qu'une méthode énoncée.

---

## Le chiffre qui fonde la méthode

**Sur 93 risques identifiés par analyse statique du dépôt, 68 ont été réfutés
après vérification adverse. 73 % de faux positifs.**

Et les constats décisifs n'ont été trouvés par aucune lecture :

| Constat | Sorti par |
|---|---|
| Le rôle métier n'était jamais posé | une requête sous vraie identité |
| `rappel-rdv` cassée depuis toujours (`.schema()` mal placé) | un `curl` |
| `creneau` est un `tstzrange`, la requête ne pouvait pas marcher | le `curl` suivant |
| Index `ivfflat` irreconstructible sur le gabarit | un `VACUUM FULL` |
| Le journal d'audit plus lourd que les données | un `pg_database_size` |

> **Rien ne se déduit, tout se relève.** Un plan de migration écrit à la
> lecture du dépôt est faux aux trois quarts — et faux de façon convaincante,
> ce qui est pire.

---

## Phase 0 — Cadrage

Les cinq questions, et les réponses pour ce cas :

| Question | Réponse ici |
|---|---|
| HDS : obligation ou confort ? | Scénario HDS assumé — données de santé pour le compte d'un tiers |
| Souveraineté exigée ? | Oui, et la source est en **Irlande** : c'est l'argument de la démo |
| Fenêtre d'indisponibilité ? | À arbitrer — le relevé donne la borne basse |
| Volumétrie de production | 20 001 consultations, 20 003 rendez-vous, 501 patients, 363 Mo |
| Qui exploite après ? | Question ouverte, et elle décide de l'option Kubernetes |

---

## Phase 1 — Relevé

```bash
SUPABASE_DB_URL='...' releve-supabase.sh > releve.json
SUPABASE_DB_URL='...' mesures-cout.sh > mesures.json
```

### Ce que le relevé a donné

| | |
|---|---|
| PostgreSQL | 17.6, gabarit NANO, 363 Mo |
| Extensions | **16**, dont `postgis` 3.3.7, `vector` 0.8.2, `pgmq` 1.5.1, `pg_cron` 1.6.4, `pg_net` 0.20.4, `supabase_vault` 0.3.1, **`pgsodium` 3.1.8**, `pgjwt` 0.2.0 |
| Policies | 57 (`medical` 42, `storage` 11, `realtime` 2, `cron` 2) |
| Rôles avec `BYPASSRLS` | **5** — `postgres`, `service_role`, `supabase_admin`, `supabase_etl_admin`, `supabase_read_only_user` |
| `FORCE ROW LEVEL SECURITY` | `medical.consultations`, `medical.documents` |
| Chiffrement transparent | 2 `SECURITY LABEL` pgsodium, dont `medical.patients.nir_chiffre` |
| Jobs `pg_cron` | 5, tous actifs |
| Secrets Vault | 3 |
| Buckets | 4, avec limites de taille **et types MIME imposés** |
| `statement_timeout` | 2 min |
| `maintenance_work_mem` | **32 Mo** |

Deux choses que je n'avais pas vues à l'œil nu et que le relevé a sorties :
**cinq** rôles portent `BYPASSRLS`, pas deux ; et il existe un **second**
`SECURITY LABEL`, sur la table de clés de pgsodium elle-même.

### Ce que les mesures ont donné

| Opération | Mesure |
|---|---|
| `pg_dump --schema-only` | 7,0 s → 73 Ko |
| `pg_dump --data-only` (20 k vecteurs) | **1 min 42 s → 324 Mo** |
| `pg_dump` auth + storage | 6,9 s → 143 Ko |
| Reconstruction index `ivfflat` | **45,5 s** → 158 Mo |

**Le dump texte double le volume des vecteurs** : 324 Mo de SQL pour 175 Mo de
table, parce que `pg_dump` écrit `[0.123,0.456,…]` au lieu du binaire `float4`.
Extrapoler sur l'octet de dump, jamais sur la taille de table.

### Les quatre plafonds

Tous silencieux jusqu'à ce qu'on les touche :

1. **`maintenance_work_mem` = 32 Mo**, l'index en réclame 65. Sur ce gabarit
   l'index est **irreconstructible**, donc `VACUUM FULL` l'est aussi. Et le
   pooler **filtre `PGOPTIONS`** : la valeur doit être posée par `SET` dans la
   session. Deux pièges enchaînés.
2. **`statement_timeout` = 2 min** — tout traitement de masse se découpe.
3. **500 Mo de plan gratuit**, atteint en cours de chargement.
4. **Bloat MVCC** : remplir les embeddings a fait passer le TOAST de 168 à
   329 Mo. Un `UPDATE` de masse coûte transitoirement le double.

### Et le poste qu'on n'attendait pas

`audit.journal_acces` est monté à **268 Mo pour 40 001 lignes** — plus lourd
que les données qu'il trace. Le trigger stocke la ligne complète en JSONB,
**embedding de 1536 dimensions inclus** : chaque vecteur est stocké deux fois.
Son job de purge ne coupe qu'à **trois ans**, donc ne se déclenche jamais sur
un déploiement neuf.

Pour une cible HDS, c'est structurant : la traçabilité des accès est une
obligation, et elle se dimensionne dès la conception.

---

## Phase 2 — Arbitrages → PORTE 1

La cartographie complète est dans [CLAUDE.md](CLAUDE.md). Les arbitrages qui
demandent une décision du client :

| Composant | Recommandation | Ce qu'on perd sinon |
|---|---|---|
| `pg_graphql` | **on ne porte pas** — activée, jamais appelée | du temps, pour rien |
| `pgsodium` / TCE du NIR | chiffrement applicatif (`lib/chiffrement.ts`) | le `SECURITY LABEL` ne se restaure pas ; il n'y a pas d'autre option |
| `pg_cron` + `pg_net` | tâches planifiées Clever Cloud | la logique reste dans la base, intestable hors production |
| Database Webhooks | réécriture applicative | dépendance à une surcouche propriétaire |
| `supabase_vault` | variables d'environnement | rien — c'est un gain net |
| `pgmq` | arbitrage : add-on de messagerie ou extension conservée | à trancher sur la volumétrie réelle |
| PostgREST, GoTrue, Realtime, imgproxy | 4 conteneurs → **la question Kubernetes se pose** | un poste d'exploitation |

### La règle des quatre issues

Par ordre de préférence, on s'arrête au premier qui répond :

1. **On ne porte pas.** L'option la plus rentable, et celle qu'on oublie.
2. **Add-on managé.** Sauvegardes, supervision et montées de version ne sont
   plus à la charge du client.
3. **Réécriture applicative.** Souvent plus simple que de porter le mécanisme.
4. **Conteneur**, en comptant son coût réel. Au-delà de trois interdépendants,
   basculer sur Kubernetes plutôt que d'empiler des applications.

---

## Phase 6 — Recette

Le livrable qui prouve la migration :

```bash
./scripts/sessions-mfa.py     # sessions reelles + TOTP, aucun mot de passe
./scripts/recette-rls.py      # matrice ressource x identite
```

Matrice mesurée sur la source :

```
                  anon    patient   praticien   secretariat
cabinets          2       2         2           2
patients          0       1         1           0
prises_en_charge  0       1         1           0
rendez_vous       0       3         20003       0
consultations     0       1         1           0
mon_agenda        0       0         3           0
```

Rejouée à l'identique sur Clever Cloud : **matrice identique = reprise
fidèle**. Une case qui change désigne exactement le problème, sans relire une
seule policy.

Deux enseignements déjà lisibles dans cette matrice :

- **le secrétariat ne voit rien** alors que le README lui promet l'agenda et
  l'identité des patients. Confirmé sous vraie identité, avec le bon
  `role_metier` et un JWT valide : le modèle n'a aucun lien secrétaire↔cabinet ;
- **le praticien voit 20 003 rendez-vous mais 1 consultation.** La policy des
  rendez-vous ne teste que `praticien_id`, celle des consultations exige en
  plus une prise en charge. L'agenda fuit plus largement que le dossier
  médical — à revérifier après bascule, c'est typiquement l'écart qu'une
  reprise « fidèle » introduit sans qu'on le voie.

---

## Scalabilité : deux chiffres

1. **`pool × instances ≤ limite de connexions de l'add-on`.** Premier mur à
   l'autoscaling.
2. **Le gabarit minimal se choisit sur le pic, pas sur la charge nominale.**
   Ici, l'application ne peut pas reconstruire son propre index vectoriel sur
   son propre gabarit : 32 Mo disponibles contre 65 requis. Prévoir une
   instance de build dédiée.

---

## Ce qu'un agent ne peut pas faire

À annoncer au cadrage, sous peine de bloquer en phase de reprise :

- récupérer les clés d'API et le mot de passe de la base — console uniquement ;
- installer un module d'Integrations (Database Webhooks) — bouton de la
  console, sans équivalent CLI ;
- tout ce qui touche à des identifiants en clair.

Tout le reste s'est fait en ligne de commande, **y compris ce que
[DEPLOIEMENT.md](DEPLOIEMENT.md) donnait pour manuel** : activation du hook
GoTrue, jobs cron, trigger de webhook.
