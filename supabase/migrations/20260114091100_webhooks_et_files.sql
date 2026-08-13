-- ---------------------------------------------------------------------------
-- 11. Database Webhooks et files de traitement
-- ---------------------------------------------------------------------------
-- Deux mecanismes propres a Supabase Cloud :
--   - supabase_functions.http_request() : les "Database Webhooks" du dashboard.
--     C'est une surcouche maison a pg_net, absente d'un PostgreSQL standard.
--   - pgmq : les "Supabase Queues", file d'attente transactionnelle.
-- Les deux sont des points de rupture pour une migration.
-- ---------------------------------------------------------------------------

-- --- Database Webhook : rendez-vous confirme -> Edge Function ---------------
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'supabase_functions') then
    raise warning 'supabase_functions absent : activez Database Webhooks dans le dashboard.';
    return;
  end if;

  create trigger rdv_confirme_webhook
    after update of statut on medical.rendez_vous
    for each row
    when (new.statut = 'confirme' and old.statut is distinct from 'confirme')
    execute function supabase_functions.http_request(
      'https://PROJECT_REF.supabase.co/functions/v1/rappel-rdv',
      'POST',
      '{"Content-Type":"application/json"}',
      '{}',
      '5000'
    );
exception when duplicate_object then null;
end
$$;

comment on table medical.rendez_vous is
  'Le trigger rdv_confirme_webhook utilise supabase_functions.http_request, specifique a Supabase Cloud.';

-- --- Files d'attente (pgmq) -------------------------------------------------
do $$
begin
  create extension if not exists pgmq;
exception when others then
  raise warning 'pgmq absent : les files d''attente ne sont pas creees.';
end
$$;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgmq') then
    return;
  end if;

  -- Envoi differe des ordonnances au pharmacien designe
  perform pgmq.create('ordonnances_a_transmettre');
  -- Export mensuel vers l'Assurance Maladie
  perform pgmq.create('exports_cnam');
  -- Recalcul des embeddings apres modification d'un compte rendu
  perform pgmq.create('embeddings_a_recalculer');
end
$$;

-- Empiler un recalcul d'embedding a chaque compte rendu modifie
create or replace function medical.empiler_recalcul_embedding()
returns trigger language plpgsql security definer set search_path = medical, public as $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgmq') then
    return new;
  end if;

  if new.compte_rendu is distinct from old.compte_rendu then
    perform pgmq.send('embeddings_a_recalculer', jsonb_build_object('consultation_id', new.id));
  end if;

  return new;
end;
$$;

do $$
begin
  create trigger recalcul_embedding
    after update on medical.consultations
    for each row execute function medical.empiler_recalcul_embedding();
exception when duplicate_object then null;
end
$$;

-- RPC de lecture de file, appelee par l'Edge Function de traitement
create or replace function public.lire_file(p_file text, p_lot int default 10)
returns setof jsonb
language plpgsql security definer set search_path = public, pgmq as $$
begin
  return query
    select message from pgmq.read(p_file, 30, p_lot);
end;
$$;

revoke execute on function public.lire_file(text, int) from public, anon, authenticated;
grant execute on function public.lire_file(text, int) to service_role;
