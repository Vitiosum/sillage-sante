-- ---------------------------------------------------------------------------
-- A executer APRES `supabase db push` et `supabase functions deploy`.
--
-- NE MODIFIE PAS CE FICHIER. Il est suivi par git et le depot est public :
-- y coller la cle service_role la publie au commit suivant.
--
-- Lancer a la place :
--     ./scripts/post-deploiement.sh <project-ref>
--
-- Il produit post-deploiement.local.sql (ignore par git) avec les valeurs
-- substituees, a coller dans le SQL Editor puis a supprimer.
--
-- Coller dans un onglet VIDE : le SQL Editor conserve le contenu precedent
-- et executerait les deux scripts concatenes.
-- ---------------------------------------------------------------------------
-- Le SQL Editor execute tout le batch dans une seule transaction : une seule
-- instruction en erreur annule TOUT le reste. Les etapes qui dependent d'un
-- composant optionnel sont donc gardees par un bloc `do $$` qui degrade en
-- avertissement au lieu de faire tomber le script.
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

-- 4. Traitement des files pgmq toutes les 5 minutes
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

-- 5. Brancher le Database Webhook sur la bonne URL de projet
--    (le trigger a ete cree avec un placeholder PROJECT_REF)
--
--    `supabase_functions` est une surcouche maison a pg_net, creee par
--    l'activation des Database Webhooks dans le dashboard. Sur un projet
--    neuf, le schema n'existe pas : sans la garde ci-dessous, cette etape
--    faisait echouer la transaction et annulait les etapes 1 a 4.
--
--    Pour l'activer : Dashboard > Integrations > Webhooks > Enable, puis
--    relancer ce script.
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'supabase_functions') then
    raise warning 'Database Webhooks non actives : trigger rdv_confirme_webhook non cree. Dashboard > Integrations > Webhooks > Enable, puis relancer.';
    return;
  end if;

  drop trigger if exists rdv_confirme_webhook on medical.rendez_vous;

  execute $trg$
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
  $trg$;
end
$$;

-- 6. Positionner les cabinets de demonstration (PostGIS)
--    Ne fait rien tant que seed.sql n'a pas ete joue : `supabase db push`
--    ne l'execute pas (verifie : la sortie rend "seeds":[]).
update medical.cabinets set position = extensions.st_point(-2.2137, 47.2735)::extensions.geography
 where finess = '440000123';   -- Saint-Nazaire
update medical.cabinets set position = extensions.st_point(-3.3660, 47.7480)::extensions.geography
 where finess = '560000456';   -- Lorient

-- ---------------------------------------------------------------------------
-- 7. Verifications, en dernier
--    Le SQL Editor n'affiche que le resultat du DERNIER select d'un batch :
--    lancer ces quatre requetes une par une (selectionner la ligne puis Run).
-- ---------------------------------------------------------------------------
select jobid, jobname, schedule, active from cron.job order by jobname;
select name, description from vault.secrets order by name;
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';
select tgname from pg_trigger where tgrelid = 'medical.rendez_vous'::regclass and not tgisinternal;
