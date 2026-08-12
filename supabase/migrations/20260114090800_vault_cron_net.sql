-- ---------------------------------------------------------------------------
-- 09. Vault, pg_net et pg_cron
-- ---------------------------------------------------------------------------

-- --- Secrets stockes dans le Vault -----------------------------------------
select vault.create_secret(
  'https://scan.interne.example/v1/scan',
  'antivirus_url',
  'Endpoint de l''antivirus appele a chaque depot de document'
);

select vault.create_secret(
  'a-remplacer-au-deploiement',
  'antivirus_token',
  'Jeton Bearer de l''antivirus'
);

select vault.create_secret(
  'a-remplacer-au-deploiement',
  'service_role_key',
  'Cle service_role utilisee par pg_cron pour invoquer les Edge Functions'
);

-- --- Appel sortant a chaque depot de document (pg_net) ----------------------
create or replace function medical.notifier_document_depose()
returns trigger language plpgsql security definer set search_path = medical, public, extensions as $$
declare
  v_url   text;
  v_token text;
begin
  select decrypted_secret into v_url   from vault.decrypted_secrets where name = 'antivirus_url';
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'antivirus_token';

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_token
    ),
    body    := jsonb_build_object(
      'document_id', new.id,
      'bucket',      new.bucket,
      'chemin',      new.chemin,
      'mime',        new.mime,
      'taille',      new.taille_octets
    ),
    timeout_milliseconds := 5000
  );

  return new;
end;
$$;

create trigger scan_document_depose
  after insert on medical.documents
  for each row execute function medical.notifier_document_depose();

-- --- Taches planifiees (pg_cron) -------------------------------------------

-- 1. Rappels de rendez-vous : invoque l'Edge Function toutes les heures
select cron.schedule(
  'rappels-rdv-horaire',
  '0 * * * *',
  $cron$
    select net.http_post(
      url     := 'https://xxxxxxxxxxxxxxxxxxxx.supabase.co/functions/v1/rappel-rdv',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
      ),
      body    := '{}'::jsonb
    );
  $cron$
);

-- 2. Purge du journal d'acces au-dela de la duree de conservation
select cron.schedule(
  'purge-journal-acces',
  '15 3 * * *',
  $cron$
    delete from audit.journal_acces where horodatage < now() - interval '3 years';
  $cron$
);

-- 3. Suppression des documents infectes detectes par l'antivirus
select cron.schedule(
  'purge-documents-infectes',
  '30 3 * * *',
  $cron$
    delete from medical.documents
    where statut_scan = 'infecte' and cree_a < now() - interval '7 days';
  $cron$
);

-- 4. Reindexation de l'index vectoriel
select cron.schedule(
  'reindex-embeddings',
  '0 4 * * 0',
  $cron$ reindex index concurrently medical.consultations_embedding_idx; $cron$
);
