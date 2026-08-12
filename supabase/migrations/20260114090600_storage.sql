-- ---------------------------------------------------------------------------
-- 07. Storage : buckets et policies
-- ---------------------------------------------------------------------------
-- Convention de nommage des objets :
--   documents-medicaux/{patient_id}/{annee}/{uuid}.{ext}
--   ordonnances/{patient_id}/{consultation_id}.pdf
--   avatars/{user_id}/avatar.webp
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('documents-medicaux', 'documents-medicaux', false, 52428800,
   array['application/pdf', 'image/png', 'image/jpeg', 'application/dicom']),
  ('ordonnances', 'ordonnances', false, 5242880, array['application/pdf']),
  ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

-- --- documents-medicaux (prive, URLs signees uniquement) --------------------
create policy "documents lisibles par le patient proprietaire"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents-medicaux'
    and (storage.foldername(name))[1] = medical.patient_courant()::text
  );

create policy "documents lisibles par le praticien prenant en charge"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'documents-medicaux'
    and medical.a_une_prise_en_charge(((storage.foldername(name))[1])::uuid)
    and medical.mfa_verifiee()
  );

create policy "depot de document dans le dossier autorise"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documents-medicaux'
    and (
      (storage.foldername(name))[1] = medical.patient_courant()::text
      or medical.a_une_prise_en_charge(((storage.foldername(name))[1])::uuid)
    )
  );

-- Pas de policy DELETE : la suppression passe par un batch service_role
-- apres expiration du delai de conservation legal.

-- --- ordonnances (prive) ----------------------------------------------------
create policy "ordonnance telechargeable par le patient"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'ordonnances'
    and (storage.foldername(name))[1] = medical.patient_courant()::text
  );

create policy "ordonnance deposee par le prescripteur"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ordonnances'
    and medical.a_une_prise_en_charge(((storage.foldername(name))[1])::uuid)
  );

-- --- avatars (public en lecture) --------------------------------------------
create policy "avatars publics en lecture"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars');

create policy "chacun gere son avatar"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "remplacement de son avatar"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "suppression de son avatar"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
