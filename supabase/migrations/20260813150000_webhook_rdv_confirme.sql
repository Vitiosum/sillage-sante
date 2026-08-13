-- ---------------------------------------------------------------------------
-- 16. Database Webhook sur la confirmation de rendez-vous
-- ---------------------------------------------------------------------------
-- 20260813130000 avait degrade en avertissement : le schema supabase_functions
-- n'existait pas encore. Il est cree par l'installation du module "Database
-- Webhooks" dans le dashboard (Integrations > Database Webhooks > Install).
--
-- Ce que cette installation pose reellement, releve apres coup :
--   - le schema  supabase_functions
--   - la fonction supabase_functions.http_request(), fonction TRIGGER : elle
--     ne declare aucun argument, les cinq parametres passent par TG_ARGV
--   - le role   supabase_functions_admin (NOINHERIT CREATEROLE LOGIN)
--
-- C'est exactement le point dur n°12 du README : les Database Webhooks sont
-- une surcouche maison a pg_net, absente de tout PostgreSQL standard. Sur
-- une cible Clever Cloud, ce trigger doit etre reecrit — soit en appel
-- pg_net direct, soit, plus simplement, cote applicatif.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'supabase_functions') then
    raise warning 'Database Webhooks non installes : trigger rdv_confirme_webhook non cree. Dashboard > Integrations > Database Webhooks > Install integration.';
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

  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'medical.rendez_vous'::regclass
       and tgname = 'rdv_confirme_webhook'
  ) then
    raise exception 'Trigger rdv_confirme_webhook non cree malgre un schema supabase_functions present';
  end if;
end
$$;
