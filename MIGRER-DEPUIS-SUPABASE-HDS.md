# Migrer depuis Supabase — hébergement de données de santé (HDS)

**Supplément à [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md).** Tout
ce qui y est dit reste valable : le relevé, la carte de dépendance, les durées
mesurées, la preuve de reprise. **Le HDS ajoute des contraintes, il ne change
pas la migration.**

Ce document traite ce qui s'ajoute quand l'application héberge des données de
santé à caractère personnel pour le compte d'un tiers.

> **Vérifié le 14 août 2026**, sources primaires : Legifrance, esante.gouv.fr,
> CNIL. Douze affirmations structurantes ont été soumises à contre-expertise ;
> **sept portaient une erreur matérielle**, corrigée ici. Le droit de la santé
> bouge : revérifiez dates et numéros avant toute signature.
>
> Ce document n'est pas un avis juridique. Il indique où regarder.

---

## 1. Pourquoi la question se pose

L'article L. 1111-8 du code de la santé publique impose que l'hébergement de
données de santé à caractère personnel, pour le compte de tiers, soit assuré
par un hébergeur **certifié**, et qu'il fasse **l'objet d'un contrat**.

Supabase Cloud n'est pas certifié HDS. Si vous êtes dans ce périmètre, la
question n'est pas « faut-il migrer » mais « comment, et en combien de temps ».

---

## 2. Quatre idées reçues qui coûtent cher

Elles circulent largement, y compris dans des supports professionnels. Elles
sont fausses, et vérifiables en ouvrant le référentiel.

| Idée reçue | Ce que dit le texte |
|---|---|
| **Le HDS impose le chiffrement au repos** | Le référentiel v2.0 ne contient **aucune** occurrence de « au repos ». « Chiffrement » n'y apparaît qu'une fois, en annexe, à propos des **flux**. |
| **Le HDS impose l'authentification multifacteur** | **Aucune** occurrence de « multifacteur », « authentification forte » ou « MFA ». Le référentiel renvoie à l'analyse de risque. |
| **Le HDS fixe une durée de conservation des journaux** | **Aucune durée chiffrée**, ni dans la v2.0, ni dans la v1.1. La durée relève du responsable de traitement et se fixe **au contrat**. |
| **La certification de l'hébergeur couvre vos obligations** | Elle couvre votre obligation de **recourir à un hébergeur certifié**, pour le périmètre hébergé. Elle ne couvre pas automatiquement l'ensemble de vos obligations applicatives et RGPD. |

**Ces trois exigences existent bel et bien** — chiffrement, authentification
forte, durées de conservation — mais elles viennent d'ailleurs :

- **chiffrement au repos** : obligation ferme si le traitement relève du
  référentiel CNIL « entrepôts de données de santé » ;
- **authentification forte** : arrêté du 28 mars 2022 approuvant le référentiel
  d'identification électronique des acteurs de santé ;
- **durées de conservation** : votre contrat, éclairé par les recommandations
  de la CNIL et les réponses opérationnelles de l'ANS.

**Pourquoi ça compte pour votre migration** : attribuer ces exigences au
mauvais texte, c'est dimensionner sur de mauvaises bases — et perdre la
discussion dès qu'un juriste ouvre le référentiel.

---

## 3. Le piège documentaire

Le document le mieux référencé par les moteurs de recherche sur le site de
l'ANS est une **version en concertation**, affichée en mode révision : elle
mêle le texte en vigueur et des modifications proposées, avec des marques de
suivi et une exigence manquante.

**Elle n'est pas opposable.**

Le référentiel en vigueur est la **v2.0**, approuvée par arrêté du 26 avril
2024 (JORF du 16 mai 2024).

Sur douze vérifications menées pour ce document, **neuf sont tombées sur ce
piège**. Si vous faites vérifier votre conformité par un tiers — humain ou
automatique — assurez-vous qu'il travaille sur le bon texte.

---

## 4. Ce qui contraint réellement l'architecture

C'est ici que le HDS change la conception, et non la paperasse.

### La zone de déploiement se choisit à la création

Un hébergement certifié suppose **une zone certifiée ET un contrat signé**.
Les deux, pas l'un ou l'autre.

Et le piège est silencieux : chez Clever Cloud, la zone par défaut **n'est pas
dans le périmètre certifié**, alors qu'elle tourne dans les mêmes datacenters
parisiens qu'une zone qui l'est, et partage ses plages d'adresses sortantes.
Une application créée sans préciser la région est hors périmètre tout en étant
« à Paris ». **Rien ne le signale à l'exécution** : l'application fonctionne.

Trois zones sont ouvertes au déploiement applicatif certifié : `parhds`,
`grahds`, `rbxhds`.

Formulation à retenir : *« zone certifiée + contrat signé »*, jamais
*« déployé en région HDS, donc conforme »*.

### La traçabilité est un composant, pas une case à cocher

Le référentiel ne fixe pas de durée, mais il impose la traçabilité des accès.
Concrètement, cela veut dire que **votre application doit produire et conserver
ces traces** — la journalisation de la plateforme ne suffit pas : chez la
plupart des hébergeurs, les journaux applicatifs sont conservés quelques jours
et les services managés n'exposent que les dernières lignes.

Deux régimes à gérer séparément, car leurs durées diffèrent :

- traces **techniques** : erreurs, événements système, support ;
- traces **applicatives** : accès aux données de santé.

**Dimensionnez-le au départ.** Sur l'application de référence, le journal
d'audit pesait **plus lourd que les données qu'il traçait** : il enregistrait
chaque ligne complète en JSON, vecteurs d'embedding compris, et sa purge était
réglée à trois ans — elle ne se déclenchait donc jamais sur un déploiement
neuf. Un journal mal conçu double votre volumétrie.

### Le chiffrement au repos se demande au provisionnement

Chez Clever Cloud, le chiffrement au repos de la base n'est disponible que sur
les **plans dédiés**, **n'est pas actif par défaut**, et s'active sur demande
au support.

Que le HDS l'impose ou non, c'est une décision de provisionnement : la prendre
après la mise en production coûte une migration de plus.

### La localisation couvre aussi les sauvegardes

Vérifiez les deux. Une base en France sauvegardée ailleurs ne satisfait rien.

---

## 5. Ce que vous devez obtenir de votre hébergeur

Avant de signer, pas après.

| À demander | Pourquoi |
|---|---|
| **Le certificat, et son annexe de périmètre** | L'annexe liste les sites et les services réellement couverts. C'est le seul document opposable — pas les pages commerciales, qui peuvent être en retard sur un cycle d'audit. |
| **La version courante du certificat** | Un certificat publié il y a plus d'un an ne reflète pas les audits de surveillance intervenus depuis. |
| **La liste des services couverts, zone par zone** | Tous les services d'une plateforme ne sont pas nécessairement dans le périmètre certifié, ni disponibles dans les zones certifiées. |
| **La matrice de répartition des responsabilités** | Le référentiel impose à l'hébergeur de la planifier et de la contrôler. Exigez-la écrite. |
| **Vos droits d'audit** | Possibilité de mandater un audit technique sur vos ressources, et d'obtenir la synthèse du rapport d'audit de l'hébergeur. |

**Vérifiez le certificat de façon indépendante** : l'ANS publie la liste des
hébergeurs certifiés, avec les activités couvertes et la version du référentiel
pour chacun. C'est la source à croiser avec ce que l'hébergeur vous présente.

---

## 6. Le contrat

Un contrat est **obligatoire** (L. 1111-8 CSP), et son contenu est encadré :
l'article R. 1111-11 fixe des clauses minimales — périmètre et dates du
certificat, description des prestations, lieux d'hébergement, modalités
d'audit, réversibilité.

Deux précisions utiles :

**Un contrat cadre cloud assorti d'une annexe HDS satisfait le texte.** Le
code régit le **contenu**, pas la forme : il n'exige pas un contrat séparé.

**Un accord de sous-traitance au titre du RGPD s'ajoute** aux clauses du code
de la santé publique. L'hébergeur a la qualité de sous-traitant : l'acte
juridique écrit prévu par l'article 28 du RGPD reste nécessaire.

**La clause de réversibilité mérite une lecture attentive.** Elle doit couvrir
la fin de prestation *et* l'arrêt anticipé **quel qu'en soit le motif**, y
compris la perte ou le retrait de la certification de l'hébergeur. C'est
précisément le scénario où vous en aurez besoin.

**Les échéances bougent.** Plusieurs évolutions du cadre étaient annoncées pour
fin 2026. Vérifiez l'état du droit à la date de signature, pas à la date où
vous avez commencé à y réfléchir.

---

## 7. Ce que ce document ne dit pas

- **Si vous êtes soumis à l'obligation.** Cela dépend de qui traite les
  données, pour le compte de qui, et à quel titre. Question pour votre DPO ou
  votre juriste, pas pour un document technique.
- **Les durées de conservation applicables à votre cas.** Elles se fixent au
  contrat, en fonction de la nature du traitement.
- **Le périmètre exact d'une certification donnée.** Il est dans l'annexe du
  certificat, à demander.
- **Ce qui vaut pour d'autres régimes** — SecNumCloud, ISO 27001, réglementation
  hors France. Le raisonnement se transpose, les exigences non.

---

## Pour la partie technique

Retournez à [MIGRER-DEPUIS-SUPABASE.md](MIGRER-DEPUIS-SUPABASE.md) : ce qui se
reprend, ce qui n'a aucun équivalent, les durées de bascule mesurées, et la
matrice qui prouve que la reprise est fidèle.

Cette dernière prend un sens particulier en contexte réglementé : **elle
documente que les règles d'accès aux données de santé sont identiques avant et
après migration.** C'est une pièce à conserver.
