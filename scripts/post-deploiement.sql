-- ---------------------------------------------------------------------------
-- A executer APRES `supabase db push` et `supabase functions deploy`.
-- Remplacer <PROJECT_REF> et <SERVICE_ROLE_KEY> avant de lancer.
-- ---------------------------------------------------------------------------

-- 1. Stocker la cle service_role dans le Vault (utilisee par pg_cron)
select vault.update_secret(
  (select id from vault.secrets where name = 'service_role_key'),
  '<SERVICE_ROLE_KEY>'
);

-- 2. Planifier le rappel de rendez-vous, qui invoque l'Edge Function
select cron.schedule(
  'rappels-rdv-horaire',
  '0 * * * *',
  $cron$
    select net.http_post(
      url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/rappel-rdv',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
      ),
      body    := '{}'::jsonb
    );
  $cron$
);

-- 3. Pointer le trigger antivirus vers l'Edge Function document-scan
select vault.update_secret(
  (select id from vault.secrets where name = 'antivirus_url'),
  'https://<PROJECT_REF>.supabase.co/functions/v1/document-scan'
);

-- 4. Verifications
select jobid, jobname, schedule, active from cron.job order by jobname;
select name, description from vault.secrets order by name;
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';

-- 5. Traitement des files pgmq toutes les 5 minutes
select cron.schedule(
  'traiter-files',
  '*/5 * * * *',
  $cron$
    select net.http_post(
      url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/traiter-files',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
      ),
      body    := '{}'::jsonb
    );
  $cron$
);

-- 6. Brancher le Database Webhook sur la bonne URL de projet
--    (le trigger a ete cree avec un placeholder PROJECT_REF)
drop trigger if exists rdv_confirme_webhook on medical.rendez_vous;
create trigger rdv_confirme_webhook
  after update of statut on medical.rendez_vous
  for each row
  when (new.statut = 'confirme' and old.statut is distinct from 'confirme')
  execute function supabase_functions.http_request(
    'https://<PROJECT_REF>.supabase.co/functions/v1/rappel-rdv',
    'POST',
    '{"Content-Type":"application/json"}',
    '{}',
    '5000'
  );

-- 7. Positionner les cabinets de demonstration (PostGIS)
update medical.cabinets set position = extensions.st_point(-2.2137, 47.2735)::extensions.geography
 where finess = '440000123';   -- Saint-Nazaire
update medical.cabinets set position = extensions.st_point(-3.3660, 47.7480)::extensions.geography
 where finess = '560000456';   -- Lorient
