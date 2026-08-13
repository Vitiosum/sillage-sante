-- ---------------------------------------------------------------------------
-- 09. Vault, pg_net et pg_cron
-- ---------------------------------------------------------------------------
-- Les trois dependent d'extensions qui peuvent ne pas etre activees.
-- Chaque bloc est donc conditionnel : le `db push` passe dans tous les cas,
-- et signale ce qui n'a pas pu etre installe.
-- ---------------------------------------------------------------------------

-- --- Secrets stockes dans le Vault -----------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'supabase_vault') then
    raise warning 'supabase_vault absent : secrets a placer dans les variables d''environnement.';
    return;
  end if;

  if not exists (select 1 from vault.secrets where name = 'antivirus_url') then
    perform vault.create_secret('https://scan.interne.example/v1/scan', 'antivirus_url',
      'Endpoint de l''antivirus appele a chaque depot de document');
  end if;

  if not exists (select 1 from vault.secrets where name = 'antivirus_token') then
    perform vault.create_secret('a-remplacer-au-deploiement', 'antivirus_token',
      'Jeton Bearer de l''antivirus');
  end if;

  if not exists (select 1 from vault.secrets where name = 'service_role_key') then
    perform vault.create_secret('a-remplacer-au-deploiement', 'service_role_key',
      'Cle service_role utilisee par pg_cron pour invoquer les Edge Functions');
  end if;
end
$$;

-- --- Appel sortant a chaque depot de document (pg_net) ----------------------
create or replace function medical.notifier_document_depose()
returns trigger language plpgsql security definer set search_path = medical, public, extensions as $$
declare
  v_url   text;
  v_token text;
begin
  select decrypted_secret into v_url   from vault.decrypted_secrets where name = 'antivirus_url';
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'antivirus_token';

  if v_url is null then
    return new;  -- antivirus non configure : le document reste 'en_attente'
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || coalesce(v_token, '')
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

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_net') then
    create trigger scan_document_depose
      after insert on medical.documents
      for each row execute function medical.notifier_document_depose();
  else
    raise warning 'pg_net absent : le trigger antivirus n''est pas installe.';
  end if;
exception when duplicate_object then null;
end
$$;

-- --- Taches planifiees (pg_cron) -------------------------------------------
-- L'URL du projet et la cle service_role sont injectees a la main apres le
-- premier deploiement (voir scripts/post-deploiement.sql).
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise warning 'pg_cron absent : les 4 taches planifiees ne sont pas creees.';
    return;
  end if;

  -- 2. Purge du journal d'acces au-dela de la duree de conservation
  perform cron.schedule('purge-journal-acces', '15 3 * * *',
    $cron$ delete from audit.journal_acces where horodatage < now() - interval '3 years'; $cron$);

  -- 3. Suppression des documents infectes detectes par l'antivirus
  perform cron.schedule('purge-documents-infectes', '30 3 * * *',
    $cron$ delete from medical.documents
           where statut_scan = 'infecte' and cree_a < now() - interval '7 days'; $cron$);

  -- 4. Reindexation de l'index vectoriel
  perform cron.schedule('reindex-embeddings', '0 4 * * 0',
    $cron$ reindex index concurrently medical.consultations_embedding_idx; $cron$);
end
$$;
