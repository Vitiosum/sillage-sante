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
