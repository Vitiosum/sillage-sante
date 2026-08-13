-- ---------------------------------------------------------------------------
-- 12. Storage avance : imagerie volumineuse et transformations
-- ---------------------------------------------------------------------------
-- Deux fonctionnalites Storage qui ne sont pas dans le socle S3 :
--   - upload reprenable (protocole TUS) pour les series DICOM
--   - transformation d'image a la volee (imgproxy) pour les avatars
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('imagerie', 'imagerie', false, 5368709120,
        array['application/dicom', 'application/zip', 'image/png'])
on conflict (id) do nothing;

-- Suivi des televersements repris, cote metier
create table if not exists medical.televersements (
  id           uuid primary key default extensions.uuid_generate_v4(),
  patient_id   uuid not null references medical.patients (id) on delete cascade,
  deposant_id  uuid not null references medical.profils (id),
  chemin_cible text not null,
  octets_total bigint not null,
  octets_recus bigint not null default 0,
  url_tus      text,
  termine_a    timestamptz,
  cree_a       timestamptz not null default now()
);

alter table medical.televersements enable row level security;

create policy "televersements visibles par le deposant"
  on medical.televersements for select to authenticated
  using (deposant_id = auth.uid());

create policy "creation d'un televersement autorise"
  on medical.televersements for insert to authenticated
  with check (
    deposant_id = auth.uid()
    and (patient_id = medical.patient_courant() or medical.a_une_prise_en_charge(patient_id))
  );

create policy "progression du televersement"
  on medical.televersements for update to authenticated
  using (deposant_id = auth.uid()) with check (deposant_id = auth.uid());

-- --- Policies du bucket imagerie -------------------------------------------
create policy "imagerie lisible par le praticien prenant en charge"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'imagerie'
    and medical.a_une_prise_en_charge(((storage.foldername(name))[1])::uuid)
    and medical.mfa_verifiee()
  );

create policy "depot d'imagerie par le praticien"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'imagerie'
    and medical.a_une_prise_en_charge(((storage.foldername(name))[1])::uuid)
  );

-- Vue de supervision : volumetrie par patient, pour le suivi de conservation
create or replace view public.volumetrie_stockage
with (security_invoker = on) as
  select (storage.foldername(o.name))[1] as patient_id,
         o.bucket_id,
         count(*)                        as objets,
         sum((o.metadata ->> 'size')::bigint) as octets
  from storage.objects o
  where o.bucket_id in ('documents-medicaux', 'imagerie', 'ordonnances')
  group by 1, 2;

grant select on public.volumetrie_stockage to authenticated;
