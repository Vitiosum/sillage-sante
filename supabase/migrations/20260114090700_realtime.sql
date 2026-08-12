-- ---------------------------------------------------------------------------
-- 08. Realtime
-- ---------------------------------------------------------------------------
-- Trois usages :
--   1. postgres_changes sur la messagerie et l'agenda (replication logique)
--   2. broadcast pour la signalisation WebRTC des teleconsultations
--   3. presence pour l'indicateur "le praticien a rejoint la salle"
-- ---------------------------------------------------------------------------

-- Publication consommee par le serveur Realtime
alter publication supabase_realtime add table medical.messages;
alter publication supabase_realtime add table medical.rendez_vous;
alter publication supabase_realtime add table medical.notifications;

-- REPLICA IDENTITY FULL : necessaire pour que le payload "old" soit complet
-- sur les UPDATE/DELETE, et pour que Realtime puisse evaluer les policies RLS.
alter table medical.messages      replica identity full;
alter table medical.rendez_vous   replica identity full;
alter table medical.notifications replica identity full;

-- Autorisation des canaux Realtime (Broadcast / Presence)
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
