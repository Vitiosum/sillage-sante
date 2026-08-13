-- ---------------------------------------------------------------------------
-- 08. Realtime
-- ---------------------------------------------------------------------------
-- Trois usages :
--   1. postgres_changes sur la messagerie et l'agenda (replication logique)
--   2. broadcast pour la signalisation WebRTC des teleconsultations
--   3. presence pour l'indicateur "le praticien a rejoint la salle"
-- ---------------------------------------------------------------------------

-- Publication consommee par le serveur Realtime.
-- Ajout idempotent : `alter publication ... add table` echoue si la table y est deja.
do $$
declare
  v_table text;
begin
  foreach v_table in array array['messages', 'rendez_vous', 'notifications'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'medical' and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table medical.%I', v_table);
    end if;
  end loop;
exception when undefined_object then
  raise warning 'Publication supabase_realtime absente : activez Realtime sur le projet.';
end
$$;

-- REPLICA IDENTITY FULL : necessaire pour que le payload "old" soit complet
-- sur les UPDATE/DELETE, et pour que Realtime puisse evaluer les policies RLS.
alter table medical.messages      replica identity full;
alter table medical.rendez_vous   replica identity full;
alter table medical.notifications replica identity full;

-- Autorisation des canaux Realtime (Broadcast / Presence).
-- realtime.messages appartient a supabase_realtime_admin : la creation de
-- policy peut echouer selon les droits du role de migration.
do $$
begin
  create policy "acces au canal de teleconsultation"
    on realtime.messages for select to authenticated
    using (
      exists (
        select 1 from medical.rendez_vous r
        where r.teleconsultation
          and realtime.topic() = 'teleconsultation:' || r.id::text
          and (r.patient_id = medical.patient_courant() or r.praticien_id = medical.praticien_courant())
          and now() between lower(r.creneau) - interval '15 minutes'
                        and upper(r.creneau) + interval '30 minutes'
      )
    );

  create policy "emission sur le canal de teleconsultation"
    on realtime.messages for insert to authenticated
    with check (
      exists (
        select 1 from medical.rendez_vous r
        where r.teleconsultation
          and realtime.topic() = 'teleconsultation:' || r.id::text
          and (r.patient_id = medical.patient_courant() or r.praticien_id = medical.praticien_courant())
      )
    );
exception
  when duplicate_object then null;
  when insufficient_privilege or undefined_table then
    raise warning 'Policies realtime.messages non creees : a appliquer depuis le SQL editor du dashboard.';
end
$$;
