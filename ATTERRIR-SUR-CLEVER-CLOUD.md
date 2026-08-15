# Atterrir sur Clever Cloud

*[English version](LANDING-ON-CLEVER-CLOUD.md)*

Vous avez lu [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md) et vous
savez ce qui se reprend et ce qui se réécrit. **Ce document est le chemin
concret** : ce qu'on crée, dans quel ordre, avec quelles commandes.

> Vérifié le 14 août 2026 contre la documentation officielle. Les catalogues
> bougent : vérifiez avant de vous engager sur un chiffre.

---

## 1. L'architecture cible recommandée

Celle qui convient à la majorité des projets Supabase :

```
                    ┌──────────────────────────────┐
   navigateur ────► │  votre application           │
                    │  (Node, Go, PHP, Python…)    │
                    │  = remplace PostgREST,       │
                    │    GoTrue et Realtime        │
                    └──────┬────────────────┬──────┘
                           │                │
                  ┌────────▼──────┐  ┌──────▼────────┐
                  │ add-on        │  │ Cellar        │
                  │ PostgreSQL    │  │ (S3)          │
                  └───────────────┘  └───────────────┘
                           ▲
                  ┌────────┴──────┐
                  │ cron          │  = remplace pg_cron + pg_net
                  │ clevercloud/  │
                  └───────────────┘
```

**Deux services managés et une application.** Pas de conteneur à exploiter,
pas de rôles PostgreSQL exotiques à recréer, pas de secret en base.

Si vous devez conserver la stack Supabase à l'identique — parce que vous
dépendez de *Postgres Changes*, ou que réécrire le backend n'est pas
envisageable maintenant — la cible devient **Kubernetes** avec un PostgreSQL
que vous administrez. C'est un autre métier : vous reprenez les sauvegardes,
les montées de version et la supervision de la base.

---

## 2. Provisionner, dans l'ordre

```bash
clever login
```

**Créez l'application.** Le type détermine le runtime détecté :

```bash
clever create --type node mon-app --alias mon-app --region par
```

> **Contexte réglementé** : la zone se choisit ici et **ne se rattrape pas**.
> Voir [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md).

**Ajoutez la base et le stockage.** L'option `--link` les rattache directement,
et **expose automatiquement leurs variables d'environnement** à l'application :

```bash
clever addon create postgresql-addon mon-app-pg --link mon-app
```

```bash
clever addon create cellar-addon mon-app-cellar --link mon-app
```

Sans `--plan`, le plan le moins cher est retenu. Pour la production, choisissez
un plan **dédié** : le chiffrement au repos n'y est disponible que là, n'est
pas actif par défaut, et s'active sur demande au support.

**Regardez les variables réellement injectées** — ne devinez pas leurs noms :

```bash
clever env --alias mon-app
```

Pour Cellar, il y en a exactement trois : `CELLAR_ADDON_HOST`,
`CELLAR_ADDON_KEY_ID`, `CELLAR_ADDON_KEY_SECRET`. **`HOST` est un nom d'hôte
nu, sans schéma** : préfixez `https://` vous-même dans votre client S3.

**Ajoutez vos propres variables**, depuis un fichier dotenv :

```bash
clever env import --alias mon-app < .env.production
```

---

## 3. Les correspondances, une par une

### Vos extensions PostgreSQL

47 extensions sont fournies par défaut, activables par `CREATE EXTENSION` sans
demander quoi que ce soit — dont **PostGIS et pgvector**.

Dix s'obtiennent sur ticket au support, dont **`pg_cron` et `pg_net`**.

Cinq n'existent pas et se réécrivent : `pgsodium`, `supabase_vault`, `pgmq`,
`pgjwt`, `pg_graphql`. La table de correspondance complète est dans
[MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md).

### Vos policies RLS

**Elles se reprennent telles quelles** — c'est du PostgreSQL standard. Ce qui
demande une décision, ce sont les **rôles** sur lesquels elles s'appuient :
`anon`, `authenticated` et `service_role` ne sont pas créables par défaut sur
un add-on managé. Le support étudie ce type de demande — **ni garanti, ni
exclu** : comptez le délai, et n'engagez rien sans réponse écrite.

Si vous ne voulez pas dépendre de cette demande, deux options :

- **garder la RLS** en la rattachant au rôle propriétaire, l'application
  positionnant le contexte utilisateur à chaque requête. **Prérequis absolu** :
  `alter table … force row level security` sur chaque table protégée — le rôle
  de l'add-on est propriétaire des tables, et un propriétaire contourne la RLS
  sans ce `FORCE`. L'oublier laisse toutes les policies silencieusement
  ignorées ;
- **remonter l'autorisation dans l'application**, la base ne servant plus de
  garde-fou.

La première conserve la défense en profondeur. La seconde est plus simple à
raisonner. Choisissez, mais **choisissez explicitement** : c'est la décision de
sécurité la plus structurante de la migration.

### Vos secrets du Vault

En variables d'environnement. `clever env import` les pose, la plateforme les
injecte, et ils sortent de la base — ce qui est un gain net : plus de secret
déchiffré au fil des requêtes.

### Vos tâches `pg_cron`

Un fichier `clevercloud/cron.json` à la racine du dépôt :

```json
[
  "0 * * * * $ROOT/clevercloud/tache.sh rappel-rdv",
  "*/5 * * * * $ROOT/clevercloud/tache.sh traiter-files"
]
```

**Le piège à connaître** : les crons s'exécutent sur **chaque instance**. Avec
trois instances, la tâche part trois fois. Le clustering n'est pas supporté —
la déduplication vous revient :

```bash
# En tête de clevercloud/tache.sh
if [[ "${INSTANCE_NUMBER:-0}" != "0" ]]; then
  exit 0
fi
```

En base, le job tournait une fois. Ici, autant de fois qu'il y a d'instances.
Un rappel envoyé en triple se voit ; une purge lancée en triple, beaucoup
moins.

Deux autres différences : `@reboot` n'existe pas, et les chemins doivent être
absolus — d'où `$ROOT`.

### Vos appels `pg_net` en trigger

Ils deviennent des appels HTTP depuis votre application. C'est plus verbeux, et
nettement plus testable : la logique sort de la base, où elle était invisible
au débogage.

### Vos buckets Storage

Cellar, compatible S3. Vos URL pré-signées fonctionnent avec les SDK standards
(`getSignedUrl` en Node, `generate_presigned_url` en Python).

**Ce que Cellar ne fait pas** : les policies par ligne. Le contrôle d'accès aux
objets remonte dans votre application. Et **une clé donne accès à tous les
buckets** de l'add-on : pour cloisonner, créez un second add-on et posez une
bucket policy.

**Ne stockez jamais sur le disque local** : les instances sont jetables, il est
perdu à chaque redéploiement.

### Vos Edge Functions

Des routes de votre application, ou une application dédiée. Le runtime Deno
n'est pas natif ; si vos fonctions sont en TypeScript sans dépendance Deno
spécifique, elles se transposent en Node avec peu de changements.

---

## 4. Trois chiffres à connaître avant de dimensionner

**`pool × instances ≤ connexions max de l'add-on`.** C'est le premier mur de
l'autoscaling. Un pool de 10 avec 3 instances sature un plan à 25 connexions.
Ce chiffre n'est pas publié par plan : **demandez-le au support** avant de
régler `--max-instances`.

**Le gabarit se choisit sur le pic, pas sur la charge nominale.** Build,
restauration, reconstruction d'index. Sur l'application de référence, la
reconstruction d'un index vectoriel de 20 000 entrées demande 65 Mo de
`maintenance_work_mem` — une petite instance qui n'en offre que 32 **ne peut
pas reconstruire son propre index**.

D'où l'instance de build dédiée :

```bash
clever scale --alias mon-app --min-instances 1 --max-instances 3 --build-flavor M
```

**Les sauvegardes sont quotidiennes, 7 jours.** Fréquence et rétention ne se
règlent pas soi-même — mais le **PITR** (restauration à un instant donné)
existe **sur demande au support, comme prestation facturée** (tâche de mise
en place, sur devis). Si vous veniez d'une offre Supabase avec PITR, faites la
demande au provisionnement — le coût et le délai se budgètent, pas au premier
incident.

---

## 5. Ce que ça coûte

**Vous ne trouverez pas de prix dans ce document.** Les tarifs bougent, et un
chiffre figé dans un guide devient faux sans prévenir — ce qui jette le doute
sur tout le reste. Les sources font foi :

- **Clever Cloud** — [clever.cloud/pricing](https://www.clever.cloud/pricing/),
  avec un **estimateur** qui chiffre une configuration complète, région par
  région.
- **Supabase** — [supabase.com/pricing](https://supabase.com/pricing).

### Les deux modèles ne se comparent pas plan à plan

C'est le piège de tout comparatif de coût entre les deux.

| | Supabase | Clever Cloud |
|---|---|---|
| Structure | forfait mensuel par organisation, **plus** des quotas inclus, **plus** des dépassements | consommation, **facturée à la seconde** |
| Calcul | le compute est facturé à part, par projet | ressource par ressource, au temps réellement consommé |
| Maîtrise du plafond | quotas et dépassements | **limite de dépense maximale** paramétrable |

Un forfait à quotas ne se compare pas à une consommation. **Le seul comparatif
honnête part de votre relevé** — celui de la section 2 de
[MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md) — et chiffre les deux
côtés sur *votre* usage réel.

### Ce qu'il faut compter, des deux côtés

À porter dans l'estimateur, une ligne par poste :

- **l'application** : gabarit × nombre d'instances × temps ;
- **la base** : plan retenu — et un **plan dédié** si vous avez besoin du
  chiffrement au repos ;
- **le stockage objet** : volume stocké et trafic sortant ;
- **les services que vous ajoutez** : messagerie, cache, identité.

Et de l'autre côté, ce qui **disparaît** de votre facture Supabase : les
quotas d'invocations de fonctions, de bande passante, de stockage, et le
compute par projet.

### Trois leviers propres à la facturation à la seconde

**Le gabarit minimum est le plancher que vous payez en permanence.** En
autoscaling vertical, `--min-flavor` définit ce qui tourne en continu, pas ce
qui tourne au pic. Le régler trop haut par prudence coûte 24 h sur 24.

**L'instance de build se paie au build.** `--build-flavor` permet de compiler
sur une grosse instance sans porter ce gabarit le reste du temps. C'est le
levier qui résout le cas « mon application ne peut pas reconstruire son index
sur son propre gabarit », sans surdimensionner l'exécution.

**`--max-instances` borne la facture** autant que la charge. Le plafond de
dépense se règle, il n'est pas subi.

Un corollaire agréable : **un environnement de recette ne coûte que le temps
où il tourne.** Éteint, il ne facture pas.

### Dire les choses honnêtement

Migrer n'est pas automatiquement moins cher. Vous reprenez à votre charge ce
qui était managé — un backend applicatif remplace PostgREST, GoTrue et
Realtime, et ce backend, il faut l'écrire et le maintenir.

Ce qu'on gagne se situe ailleurs : la maîtrise du plafond, la facturation au
temps réel, la localisation, et la sortie d'une dépendance à cinq composants
qui n'existent nulle part ailleurs.

**Chiffrez avant de décider, et redatez le chiffrage avant de le présenter.**

---

## 6. Déployer

```bash
clever deploy --alias mon-app
```

Le déploiement se fait par `git push` vers le remote de la plateforme. Il n'y a
**pas de fichier manifeste** type `fly.toml` : la configuration vit dans les
variables `CC_*`, les fichiers natifs de votre langage, et `clevercloud/`.

Pour une application Docker : le `Dockerfile` à la racine, `CMD` obligatoire,
et le port d'écoute déclaré par `CC_DOCKER_EXPOSED_HTTP_PORT`. Docker Compose
n'est pas supporté — une application est un conteneur.

```bash
clever logs --alias mon-app
```

---

## 7. Prouver que la reprise est fidèle

Ne concluez pas la migration sur « ça a l'air de marcher ».

Interrogez votre API sous **chaque identité métier**, sur la source **avant**
bascule, puis sur la cible **après**. Comparez les deux matrices. Identiques =
reprise fidèle ; une case qui change désigne exactement le problème.

La méthode et un harnais générique sont dans
[MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md), section 6.

C'est le seul livrable qui transforme « on pense que ça marche » en « on a
vérifié ». En contexte réglementé, c'est aussi une pièce à conserver.

---

## Ce qu'on ne vous dira pas dans une page produit

- Le **nombre de connexions par plan** n'est pas publié. Demandez-le.
- Le **chiffrement au repos** n'est ni par défaut, ni disponible partout.
- **`pg_cron` et `pg_net` passent par un ticket** — comptez le délai dans votre
  planning.
- **Postgres Changes n'est pas disponible par défaut** sur un add-on managé
  (`wal_level=logical` n'est pas exposé). Le support étudie ces demandes — ne
  planifiez jamais dessus sans confirmation écrite. Si vous en dépendez
  vraiment et sans accord écrit, c'est Kubernetes.

Mieux vaut le savoir maintenant qu'au milieu d'une bascule.
