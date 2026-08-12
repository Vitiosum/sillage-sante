-- ---------------------------------------------------------------------------
-- 01. Extensions PostgreSQL
-- ---------------------------------------------------------------------------
-- Note : sur Supabase Cloud ces extensions sont pre-packagees dans l'image
-- supabase/postgres. Sur un PostgreSQL manage standard, plusieurs d'entre
-- elles ne sont pas disponibles par defaut.
-- ---------------------------------------------------------------------------

create schema if not exists extensions;

-- Coeur : disponibles sur tout PostgreSQL
create extension if not exists "uuid-ossp"      with schema extensions;
create extension if not exists "pgcrypto"       with schema extensions;
create extension if not exists "pg_trgm"        with schema extensions;
create extension if not exists "unaccent"       with schema extensions;
create extension if not exists "btree_gist"     with schema extensions;
create extension if not exists "pg_stat_statements";

-- Specifiques a l'image Supabase
create extension if not exists "pgjwt"          with schema extensions;  -- signature des JWT en SQL
create extension if not exists "pg_graphql";                             -- endpoint /graphql/v1
create extension if not exists "pg_net"         with schema extensions;  -- appels HTTP sortants depuis la base
create extension if not exists "pg_cron";                                -- planification (purge, rappels)
create extension if not exists "pgsodium";                               -- chiffrement colonne (TCE)
create extension if not exists "supabase_vault";                         -- coffre a secrets
create extension if not exists "vector"         with schema extensions;  -- embeddings des comptes rendus

comment on extension pg_net is
  'Utilisee par le trigger medical.notifier_document_depose pour appeler l''antivirus.';
