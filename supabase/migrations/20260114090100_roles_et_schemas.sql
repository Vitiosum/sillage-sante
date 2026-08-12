-- ---------------------------------------------------------------------------
-- 02. Schemas metier et roles
-- ---------------------------------------------------------------------------

create schema if not exists medical;    -- donnees de sante, expose via PostgREST
create schema if not exists audit;      -- journal d'acces, jamais expose
create schema if not exists auth_hooks; -- fonctions appelees par GoTrue

comment on schema medical is 'Donnees de sante identifiantes. Toute table ici doit avoir RLS activee.';
comment on schema audit   is 'Tracabilite des acces. Non expose via PostgREST (absent de PGRST_DB_SCHEMAS).';

-- Roles Supabase standard : deja presents sur Supabase Cloud, recrees ici
-- pour que la base soit reconstructible ailleurs.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

-- Role metier supplementaire : batchs de nuit (purge, exports CNAM)
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'batch_runner') then
    create role batch_runner nologin noinherit;
  end if;
end
$$;

grant usage on schema public, medical to anon, authenticated, service_role;
grant usage on schema extensions to authenticated, service_role;
grant usage on schema audit to service_role, batch_runner;

alter default privileges in schema medical
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema medical
  grant select on tables to anon;
alter default privileges in schema medical
  grant usage, select on sequences to authenticated;

-- L'authenticator doit pouvoir endosser les trois roles PostgREST
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    execute 'grant anon, authenticated, service_role to authenticator';
  end if;
end
$$;
