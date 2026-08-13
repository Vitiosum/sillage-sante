-- ---------------------------------------------------------------------------
-- 01. Extensions PostgreSQL
-- ---------------------------------------------------------------------------
-- Sur Supabase Cloud, pg_cron / pg_net / pgsodium sont plus fiables lorsqu'ils
-- sont actives depuis le dashboard (Database > Extensions) : l'activation par
-- migration laisse parfois les GRANTs incomplets.
--   cf. https://github.com/supabase/cli/issues/1591
-- Cette migration est donc tolerante : elle active ce qu'elle peut et signale
-- le reste sans interrompre le `db push`.
-- ---------------------------------------------------------------------------

create schema if not exists extensions;

-- --- Socle, disponible sur tout PostgreSQL ---------------------------------
create extension if not exists "uuid-ossp"  with schema extensions;
create extension if not exists "pgcrypto"   with schema extensions;
create extension if not exists "pg_trgm"    with schema extensions;
create extension if not exists "unaccent"   with schema extensions;
create extension if not exists "btree_gist" with schema extensions;

-- --- Specifiques a l'image supabase/postgres --------------------------------
do $$
declare
  v_ext text;
  v_manquantes text[] := '{}';
begin
  foreach v_ext in array array['pgjwt', 'pg_net', 'vector'] loop
    begin
      execute format('create extension if not exists %I with schema extensions', v_ext);
    exception when others then
      v_manquantes := v_manquantes || v_ext;
    end;
  end loop;

  foreach v_ext in array array['pg_graphql', 'supabase_vault', 'pgsodium'] loop
    begin
      execute format('create extension if not exists %I', v_ext);
    exception when others then
      v_manquantes := v_manquantes || v_ext;
    end;
  end loop;

  -- pg_cron n'accepte que le schema pg_catalog sur Supabase
  begin
    create extension if not exists pg_cron with schema pg_catalog;
  exception when others then
    v_manquantes := v_manquantes || 'pg_cron';
  end;

  if array_length(v_manquantes, 1) > 0 then
    raise warning 'Extensions non activees : %. Activez-les depuis Database > Extensions puis relancez.', v_manquantes;
  end if;
end
$$;

comment on schema extensions is
  'pg_net y est utilisee par medical.notifier_document_depose(), vector par la recherche semantique.';
