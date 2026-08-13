-- ---------------------------------------------------------------------------
-- Jeu de donnees de demonstration, a jouer APRES la creation des comptes.
--
--   ./scripts/comptes-demo.sh          # cree les 3 comptes via GoTrue
--   psql "$SUPABASE_DB_URL" -f scripts/donnees-demo.sql
--
-- Aucune donnee reelle. Les utilisateurs sont retrouves par e-mail, donc ce
-- script ne depend d'aucun UUID en dur et se rejoue sans risque.
--
-- medical.consultations et medical.documents sont en FORCE ROW LEVEL
-- SECURITY. Sur Supabase Cloud ca ne gene pas : `postgres` porte BYPASSRLS,
-- qui prime sur FORCE RLS. A ne PAS tenir pour acquis ailleurs — sur un
-- PostgreSQL managé standard, le proprietaire n'a pas forcement BYPASSRLS et
-- ce script echouerait sur l'etape 4. C'est le point dur n°9 du README.
--
-- `set role service_role` ne serait pas une solution de repli : ce role a
-- bien BYPASSRLS, mais aucun droit de lecture sur auth.users.
-- ---------------------------------------------------------------------------
begin;

-- 1. Fiche praticien (le trigger ne cree que profils pour ce role)
insert into medical.praticiens (profil_id, cabinet_id, rpps, specialite, actif)
select u.id, c.id, '10001234567', 'Medecine generale', true
  from auth.users u
  cross join medical.cabinets c
 where u.email = 'praticien@example.test'
   and c.finess = '440000123'                     -- Saint-Nazaire
   and not exists (select 1 from medical.praticiens p where p.profil_id = u.id);

-- 2. Prise en charge : c'est elle qui ouvre l'acces au dossier
insert into medical.prises_en_charge (patient_id, praticien_id, debut, motif)
select pa.id, pr.id, now() - interval '3 months', 'Suivi de medecine generale'
  from medical.patients pa
  join auth.users up on up.id = pa.profil_id and up.email = 'patient@example.test'
  cross join medical.praticiens pr
  join auth.users upr on upr.id = pr.profil_id and upr.email = 'praticien@example.test'
 where not exists (
   select 1 from medical.prises_en_charge x
    where x.patient_id = pa.id and x.praticien_id = pr.id
 );

-- 3. Rendez-vous. `creneau` est un tstzrange, avec une contrainte d'exclusion
--    gist sur (praticien_id, creneau) tant que le statut n'est pas 'annule' :
--    les trois creneaux ci-dessous ne doivent pas se chevaucher.
with acteurs as (
  select pa.id as patient_id, pr.id as praticien_id
    from medical.patients pa
    join auth.users up on up.id = pa.profil_id and up.email = 'patient@example.test'
    cross join medical.praticiens pr
    join auth.users upr on upr.id = pr.profil_id and upr.email = 'praticien@example.test'
)
insert into medical.rendez_vous (praticien_id, patient_id, creneau, statut, motif, teleconsultation)
select a.praticien_id, a.patient_id, v.creneau, v.statut, v.motif, v.teleconsultation
  from acteurs a
  cross join (values
    (tstzrange(now() - interval '7 days',  now() - interval '7 days'  + interval '30 minutes'), 'honore'::medical.statut_rdv,  'Bilan annuel',            false),
    -- Celui-ci tombe dans les 24 h : c'est la cible de l'Edge Function rappel-rdv.
    (tstzrange(now() + interval '18 hours', now() + interval '18 hours' + interval '30 minutes'), 'demande'::medical.statut_rdv, 'Renouvellement ordonnance', false),
    (tstzrange(now() + interval '10 days', now() + interval '10 days' + interval '45 minutes'), 'confirme'::medical.statut_rdv, 'Teleconsultation de suivi', true)
  ) as v(creneau, statut, motif, teleconsultation)
 where not exists (
   select 1 from medical.rendez_vous r
    where r.praticien_id = a.praticien_id and r.creneau && v.creneau
 );

-- 4. Compte rendu sur le rendez-vous passe
insert into medical.consultations (rendez_vous_id, praticien_id, patient_id, compte_rendu, diagnostic_cim10, duree_minutes, cloturee_a)
select r.id, r.praticien_id, r.patient_id,
       'Patient vu en consultation de suivi. Tension 12/8, poids stable. '
    || 'Renouvellement du traitement antihypertenseur pour six mois. '
    || 'Controle biologique demande : ionogramme et creatininemie.',
       array['I10'], 30, now() - interval '7 days' + interval '30 minutes'
  from medical.rendez_vous r
 where r.statut = 'honore'
   and not exists (select 1 from medical.consultations c where c.rendez_vous_id = r.id);

commit;
