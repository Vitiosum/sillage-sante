-- ---------------------------------------------------------------------------
-- 14. Post-deploiement, tout ce qui ne contient aucun secret
-- ---------------------------------------------------------------------------
-- scripts/post-deploiement.sql devait etre colle dans le SQL Editor parce
-- qu'il porte la cle service_role. En realite une seule de ses instructions
-- la contient : `vault.update_secret('service_role_key', ...)`. Toutes les
-- autres lisent le Vault a l'execution via vault.decrypted_secrets.
--
-- Cette migration reprend donc tout le reste, ce qui evite un copier-coller
-- de cent lignes dans un editeur qui empile les onglets. Reste a jouer a la
-- main, une seule ligne :
--
--   select vault.update_secret(
--     (select id from vault.secrets where name = 'service_role_key'),
--     '<la cle secrete>');
--
-- Les jobs cron sont inertes tant que ce secret n'est pas pose : le header
-- Authorization vaudra NULL et l'Edge Function repondra 401.
-- ---------------------------------------------------------------------------

-- 1. URL de l'Edge Function antivirus (ce n'est pas un secret)
do $$
begin
  perform vault.update_secret(
    (select id from vault.secrets where name = 'antivirus_url'),
    'https://hdhmnoliwhsqiuawqrnp.supabase.co/functions/v1/document-scan'
  );
exception when others then
  raise warning 'Vault indisponible : antivirus_url non mis a jour (%)', sqlerrm;
end
$$;

-- 2. Rappel de rendez-vous, toutes les heures
do $$
begin
  perform cron.schedule(
    'rappels-rdv-horaire',
    '0 * * * *',
    $cron$
      select net.http_post(
        url     := 'https://hdhmnoliwhsqiuawqrnp.supabase.co/functions/v1/rappel-rdv',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
        ),
        body    := '{}'::jsonb
      );
    $cron$
  );
exception when others then
  raise warning 'Job rappels-rdv-horaire non planifie (%)', sqlerrm;
end
$$;

-- 3. Consommation des files pgmq, toutes les 5 minutes
do $$
begin
  perform cron.schedule(
    'traiter-files',
    '*/5 * * * *',
    $cron$
      select net.http_post(
        url     := 'https://hdhmnoliwhsqiuawqrnp.supabase.co/functions/v1/traiter-files',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
        ),
        body    := '{}'::jsonb
      );
    $cron$
  );
exception when others then
  raise warning 'Job traiter-files non planifie (%)', sqlerrm;
end
$$;

-- 4. Database Webhook sur la confirmation de rendez-vous
--    `supabase_functions` est une surcouche maison a pg_net, creee par
--    l'activation des Database Webhooks dans le dashboard. Absente d'un
--    projet neuf : sans cette garde, l'erreur 3F000 annule tout le batch.
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'supabase_functions') then
    raise warning 'Database Webhooks non actives : trigger rdv_confirme_webhook non cree. Dashboard > Integrations > Webhooks > Enable, puis rejouer cette migration.';
    return;
  end if;

  drop trigger if exists rdv_confirme_webhook on medical.rendez_vous;

  execute $trg$
    create trigger rdv_confirme_webhook
      after update of statut on medical.rendez_vous
      for each row
      when (new.statut = 'confirme' and old.statut is distinct from 'confirme')
      execute function supabase_functions.http_request(
        'https://hdhmnoliwhsqiuawqrnp.supabase.co/functions/v1/rappel-rdv',
        'POST',
        '{"Content-Type":"application/json"}',
        '{}',
        '5000'
      );
  $trg$;
end
$$;

-- 5. Cabinets de demonstration (PostGIS)
--    Sans effet tant que seed.sql n'a pas ete joue : `supabase db push` ne
--    l'execute pas (verifie, la sortie rend "seeds":[]).
update medical.cabinets set position = extensions.st_point(-2.2137, 47.2735)::extensions.geography
 where finess = '440000123';   -- Saint-Nazaire
update medical.cabinets set position = extensions.st_point(-3.3660, 47.7480)::extensions.geography
 where finess = '560000456';   -- Lorient
