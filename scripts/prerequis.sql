-- ---------------------------------------------------------------------------
-- A executer EN PREMIER dans le SQL Editor du dashboard Supabase,
-- avant `supabase db push`.
-- Dashboard > SQL Editor > New query > coller > Run.
-- ---------------------------------------------------------------------------
-- Certaines extensions s'activent mal depuis une migration : les GRANTs sont
-- incomplets et pg_cron refuse tout schema autre que pg_catalog.
-- On les active donc ici, une bonne fois.
-- ---------------------------------------------------------------------------

create schema if not exists extensions;

create extension if not exists "uuid-ossp"   with schema extensions;
create extension if not exists "pgcrypto"    with schema extensions;
create extension if not exists "pg_trgm"     with schema extensions;
create extension if not exists "unaccent"    with schema extensions;
create extension if not exists "btree_gist"  with schema extensions;
create extension if not exists "pgjwt"       with schema extensions;
create extension if not exists "pg_net"      with schema extensions;
create extension if not exists "vector"      with schema extensions;

create extension if not exists "pg_graphql";
create extension if not exists "supabase_vault";

-- pg_cron n'accepte que pg_catalog sur Supabase
create extension if not exists "pg_cron" with schema pg_catalog;

-- pgsodium est deprecie par Supabase et peut ne pas etre disponible.
-- Si cette ligne echoue, ce n'est pas bloquant : le chiffrement du NIR
-- bascule sur la couche applicative (lib/chiffrement.ts).
create extension if not exists "pgsodium";

-- Verification
select extname, extversion
from pg_extension
order by extname;
