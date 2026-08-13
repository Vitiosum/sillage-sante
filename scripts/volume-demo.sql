-- ---------------------------------------------------------------------------
-- Charge de volume, pour rendre mesurable la fenetre de bascule.
--
--   psql "$SUPABASE_DB_URL" -v n=20000 -f scripts/volume-demo.sql
--
-- Sans volume, un dump de 8 Ko ne dit rien : on ne peut ni chiffrer la duree
-- d'un pg_dump/restore, ni surtout celle de la RECONSTRUCTION DE L'INDEX
-- ivfflat, qui est le vrai cout cache d'une migration pgvector.
--
-- Dimensionnement : un vector(1536) pese ~6 Ko. L'index ivfflat pese a peu
-- pres autant que les donnees. Le plan gratuit plafonne a 500 Mo, d'ou
-- n=20000 par defaut (~120 Mo + ~120 Mo). Mesurer avant d'aller plus haut.
--
-- Les patients de volume n'ont pas de profil_id (la colonne est nullable) :
-- inutile de creer 500 comptes auth pour du remplissage.
--
-- Rejouable : chaque etape ignore ce qui existe deja.
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP on
\timing on

-- 1. Patientele de volume
insert into medical.patients (nom_naissance, prenom, date_naissance)
select 'Volume' || i, 'Demo', date '1950-01-01' + (i * 7)
  from generate_series(1, 500) i
 where not exists (select 1 from medical.patients where nom_naissance = 'Volume' || i);

-- 2. Rendez-vous. La contrainte d'exclusion gist interdit tout chevauchement
--    pour un meme praticien : on aligne des creneaux de 30 min consecutifs,
--    dans le passe pour ne pas heurter les trois rendez-vous de demonstration.
with pats as (
  select id, (row_number() over (order by id)) - 1 as rn
    from medical.patients where nom_naissance like 'Volume%'
),
nb as (select count(*)::int as c from pats),
prat as (select id from medical.praticiens order by id limit 1)
insert into medical.rendez_vous (praticien_id, patient_id, creneau, statut, motif)
select prat.id,
       pats.id,
       tstzrange(d.debut, d.debut + interval '30 minutes'),
       'honore'::medical.statut_rdv,
       'Consultation de volume'
  from generate_series(1, :n) i
  cross join prat
  cross join nb
  join pats on pats.rn = i % nb.c
  cross join lateral (
    select date_trunc('hour', now() - interval '13 years') + (i * interval '30 minutes') as debut
  ) d
 where not exists (
   select 1 from medical.rendez_vous r
    where r.praticien_id = prat.id
      and r.creneau && tstzrange(d.debut, d.debut + interval '30 minutes')
 );

-- 3. Comptes rendus
insert into medical.consultations (rendez_vous_id, praticien_id, patient_id, compte_rendu, diagnostic_cim10, duree_minutes, cloturee_a)
select r.id, r.praticien_id, r.patient_id,
       'Consultation de suivi. Examen clinique sans particularite. '
    || 'Traitement poursuivi a l''identique. Prochain controle dans six mois. '
    || 'Reference interne ' || r.id::text,
       array['Z00'], 30, upper(r.creneau)
  from medical.rendez_vous r
 where r.motif = 'Consultation de volume'
   and not exists (select 1 from medical.consultations c where c.rendez_vous_id = r.id);

-- 4. Embeddings.
--    100 vecteurs de base plutot que n vecteurs aleatoires : generer
--    20000 x 1536 random() couterait des minutes pour rien. Ce qui compte
--    pour le cout de l'index ivfflat, c'est le nombre de vecteurs, leur
--    dimension et leur repartition en grappes — pas leur entropie. Avec
--    lists=100, 100 grappes est exactement le cas nominal.
--    Pas de `on commit drop` : en autocommit, la table temporaire serait
--    detruite au commit implicite de sa propre creation. On englobe les deux
--    instructions dans une transaction explicite.
begin;

create temp table bases as
select i as k,
       (select array_agg(random()::real) from generate_series(1, 1536))::vector(1536) as v
  from generate_series(0, 99) i;

with num as (
  select id, (row_number() over (order by id)) % 100 as k
    from medical.consultations where embedding is null
)
update medical.consultations c
   set embedding = b.v
  from num, bases b
 where c.id = num.id and b.k = num.k;

drop table bases;
commit;

-- 5. Etat
select 'consultations           = ' || count(*) from medical.consultations
union all select 'dont avec embedding     = ' || count(*) from medical.consultations where embedding is not null
union all select 'rendez_vous             = ' || count(*) from medical.rendez_vous
union all select 'patients                = ' || count(*) from medical.patients
union all select 'taille base             = ' || pg_size_pretty(pg_database_size(current_database()))
union all select 'table consultations     = ' || pg_size_pretty(pg_total_relation_size('medical.consultations'))
union all select 'index ivfflat           = ' || pg_size_pretty(pg_relation_size('medical.consultations_embedding_idx'));
