-- ---------------------------------------------------------------------------
-- 04. Fonctions SQL, triggers et RPC exposees a PostgREST
-- ---------------------------------------------------------------------------

-- --- Utilitaires -----------------------------------------------------------
create or replace function medical.touch_maj_a()
returns trigger language plpgsql as $$
begin
  new.maj_a := now();
  return new;
end;
$$;

create trigger touch_profils      before update on medical.profils      for each row execute function medical.touch_maj_a();
create trigger touch_patients     before update on medical.patients     for each row execute function medical.touch_maj_a();
create trigger touch_rdv          before update on medical.rendez_vous  for each row execute function medical.touch_maj_a();
create trigger touch_consultations before update on medical.consultations for each row execute function medical.touch_maj_a();

-- --- Helpers d'autorisation, utilises par les policies RLS -----------------
-- Ces fonctions s'appuient directement sur les claims GoTrue.

create or replace function medical.profil_courant()
returns uuid language sql stable as $$
  select auth.uid();
$$;

create or replace function medical.role_courant()
returns medical.role_metier language sql stable as $$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role_metier')::medical.role_metier,
    (select role_metier from medical.profils where id = auth.uid()),
    'patient'::medical.role_metier
  );
$$;

create or replace function medical.praticien_courant()
returns uuid language sql stable security definer set search_path = medical, public as $$
  select p.id from medical.praticiens p
  where p.profil_id = auth.uid() and p.actif;
$$;

create or replace function medical.patient_courant()
returns uuid language sql stable security definer set search_path = medical, public as $$
  select p.id from medical.patients p where p.profil_id = auth.uid();
$$;

-- Le praticien a-t-il une prise en charge active sur ce patient ?
create or replace function medical.a_une_prise_en_charge(p_patient_id uuid)
returns boolean language sql stable security definer set search_path = medical, public as $$
  select exists (
    select 1
    from medical.prises_en_charge pec
    join medical.praticiens pr on pr.id = pec.praticien_id
    where pec.patient_id = p_patient_id
      and pr.profil_id = auth.uid()
      and (pec.fin is null or pec.fin >= current_date)
  );
$$;

-- Niveau d'assurance MFA porte par le JWT GoTrue
create or replace function medical.mfa_verifiee()
returns boolean language sql stable as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;

comment on function medical.mfa_verifiee is
  'Les policies sur les comptes rendus exigent aal2 : un praticien connecte sans second facteur ne lit pas le contenu medical.';

-- --- Provisionnement du profil a l''inscription ----------------------------
create or replace function medical.gerer_nouvel_utilisateur()
returns trigger language plpgsql security definer set search_path = medical, public as $$
declare
  v_role medical.role_metier;
begin
  v_role := coalesce(
    (new.raw_app_meta_data ->> 'role_metier')::medical.role_metier,
    'patient'
  );

  insert into medical.profils (id, role_metier, nom, prenom, telephone, avatar_url)
  values (
    new.id,
    v_role,
    coalesce(new.raw_user_meta_data ->> 'nom', 'A completer'),
    coalesce(new.raw_user_meta_data ->> 'prenom', ''),
    new.phone,
    new.raw_user_meta_data ->> 'avatar_url'
  );

  -- Un patient qui s'inscrit obtient immediatement son dossier
  if v_role = 'patient' then
    insert into medical.patients (profil_id, nom_naissance, prenom, date_naissance)
    values (
      new.id,
      coalesce(new.raw_user_meta_data ->> 'nom', 'A completer'),
      coalesce(new.raw_user_meta_data ->> 'prenom', ''),
      coalesce((new.raw_user_meta_data ->> 'date_naissance')::date, '1900-01-01')
    );
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function medical.gerer_nouvel_utilisateur();

-- Suppression RGPD : on anonymise plutot que de casser l'historique de soins
create or replace function medical.anonymiser_utilisateur()
returns trigger language plpgsql security definer set search_path = medical, public as $$
begin
  update medical.patients
     set nom_naissance = 'ANONYMISE',
         prenom = '',
         nir_chiffre = null,
         profil_id = null
   where profil_id = old.id;
  return old;
end;
$$;

create trigger on_auth_user_deleted
  before delete on auth.users
  for each row execute function medical.anonymiser_utilisateur();

-- --- Journal d'acces -------------------------------------------------------
create or replace function audit.tracer()
returns trigger language plpgsql security definer set search_path = audit, medical, public as $$
begin
  insert into audit.journal_acces (acteur_id, role_effectif, action, table_cible, ligne_id, avant, apres)
  values (
    auth.uid(),
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    tg_op,
    tg_table_name,
    coalesce(new.id, old.id),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create trigger tracer_consultations after insert or update or delete on medical.consultations
  for each row execute function audit.tracer();
create trigger tracer_documents after insert or update or delete on medical.documents
  for each row execute function audit.tracer();
create trigger tracer_ordonnances after insert or update or delete on medical.ordonnances
  for each row execute function audit.tracer();

-- --- RPC appelees depuis le front via supabase.rpc() -----------------------

-- Reserver un creneau : encapsule la contrainte d'exclusion
create or replace function public.reserver_creneau(
  p_praticien_id uuid,
  p_debut timestamptz,
  p_duree_minutes int default 30,
  p_motif text default null,
  p_teleconsultation boolean default false
)
returns medical.rendez_vous
language plpgsql security definer set search_path = medical, public as $$
declare
  v_patient_id uuid;
  v_rdv medical.rendez_vous;
begin
  v_patient_id := medical.patient_courant();
  if v_patient_id is null then
    raise exception 'Aucun dossier patient rattache a ce compte' using errcode = '42501';
  end if;

  insert into medical.rendez_vous (praticien_id, patient_id, creneau, motif, teleconsultation, statut)
  values (
    p_praticien_id,
    v_patient_id,
    tstzrange(p_debut, p_debut + make_interval(mins => p_duree_minutes), '[)'),
    p_motif,
    p_teleconsultation,
    'demande'
  )
  returning * into v_rdv;

  -- Le praticien devient prenant en charge s'il ne l'etait pas deja
  insert into medical.prises_en_charge (patient_id, praticien_id, motif)
  values (v_patient_id, p_praticien_id, p_motif)
  on conflict do nothing;

  return v_rdv;
exception
  when exclusion_violation then
    raise exception 'Ce creneau vient d''etre reserve' using errcode = 'P0001';
end;
$$;

grant execute on function public.reserver_creneau(uuid, timestamptz, int, text, boolean) to authenticated;

-- Creneaux libres d'un praticien sur une journee
create or replace function public.creneaux_disponibles(
  p_praticien_id uuid,
  p_jour date
)
returns table (debut timestamptz, fin timestamptz)
language sql stable security definer set search_path = medical, public as $$
  with grille as (
    select generate_series(
      (p_jour + time '08:30') at time zone 'Europe/Paris',
      (p_jour + time '18:30') at time zone 'Europe/Paris',
      interval '30 minutes'
    ) as debut
  )
  select g.debut, g.debut + interval '30 minutes'
  from grille g
  where not exists (
    select 1 from medical.rendez_vous r
    where r.praticien_id = p_praticien_id
      and r.statut <> 'annule'
      and r.creneau && tstzrange(g.debut, g.debut + interval '30 minutes', '[)')
  );
$$;

grant execute on function public.creneaux_disponibles(uuid, date) to anon, authenticated;

-- Recherche plein texte dans les comptes rendus du praticien connecte
create or replace function public.rechercher_comptes_rendus(p_requete text)
returns setof medical.consultations
language sql stable set search_path = medical, public as $$
  select *
  from medical.consultations c
  where to_tsvector('french', coalesce(c.compte_rendu, ''))
        @@ plainto_tsquery('french', extensions.unaccent(p_requete))
  order by c.cree_a desc
  limit 50;
$$;

grant execute on function public.rechercher_comptes_rendus(text) to authenticated;

-- Recherche par similarite vectorielle (appelee par l'Edge Function)
create or replace function public.consultations_similaires(
  p_embedding extensions.vector(1536),
  p_seuil float default 0.78,
  p_limite int default 10
)
returns table (id uuid, compte_rendu text, similarite float)
language sql stable set search_path = medical, public, extensions as $$
  select c.id,
         c.compte_rendu,
         1 - (c.embedding <=> p_embedding) as similarite
  from medical.consultations c
  where c.embedding is not null
    and 1 - (c.embedding <=> p_embedding) > p_seuil
  order by c.embedding <=> p_embedding
  limit p_limite;
$$;

grant execute on function public.consultations_similaires(extensions.vector, float, int) to authenticated, service_role;

-- Vue exposee au front : agenda du praticien connecte
create or replace view public.mon_agenda
with (security_invoker = on) as
  select r.id,
         r.creneau,
         r.statut,
         r.motif,
         r.teleconsultation,
         p.nom_naissance,
         p.prenom,
         p.date_naissance
  from medical.rendez_vous r
  join medical.patients p on p.id = r.patient_id
  where r.praticien_id = medical.praticien_courant();

grant select on public.mon_agenda to authenticated;
