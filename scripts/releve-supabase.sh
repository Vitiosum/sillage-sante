#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Releve chiffre d'un projet Supabase, avant migration.
#
#   SUPABASE_DB_URL='postgresql://...' ./releve-supabase.sh > releve.json
#
# Ne conclut rien : il mesure. Le plan de migration se deduit de sa sortie,
# jamais de la lecture du depot.
#
# Prerequis : psql. Aucun Docker requis.
# Astuce : prendre la chaine du "Session pooler" dans la console. La connexion
# directe est en IPv6 par defaut et echoue sur un reseau IPv4.
# ---------------------------------------------------------------------------
set -euo pipefail

U="${SUPABASE_DB_URL:-}"
if [[ -z "$U" ]]; then
  echo "SUPABASE_DB_URL non definie" >&2
  exit 1
fi

PSQL=(psql "$U" -tAX -v ON_ERROR_STOP=1)

# Renvoie du JSON, ou null si la requete echoue (extension absente, droits
# manquants) : un releve partiel vaut mieux qu'un releve qui s'arrete.
j() {
  "${PSQL[@]}" -c "select coalesce((${1}), 'null'::jsonb)::text" 2>/dev/null || echo null
}

cat <<JSON
{
  "horodatage": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",

  "serveur": $(j "
    select jsonb_build_object(
      'version', current_setting('server_version'),
      'base', current_database(),
      'taille', pg_size_pretty(pg_database_size(current_database())),
      'taille_octets', pg_database_size(current_database()),
      'statement_timeout', current_setting('statement_timeout'),
      'maintenance_work_mem', current_setting('maintenance_work_mem'),
      'work_mem', current_setting('work_mem'),
      'max_connections', current_setting('max_connections'))"),

  "extensions": $(j "
    select jsonb_agg(jsonb_build_object('nom', extname, 'version', extversion, 'schema', n.nspname) order by extname)
      from pg_extension e join pg_namespace n on n.oid = e.extnamespace"),

  "chiffrement_transparent": $(j "
    select jsonb_agg(jsonb_build_object('objet', objoid::regclass::text, 'colonne', objsubid, 'label', label))
      from pg_seclabel where provider = 'pgsodium'"),

  "roles": $(j "
    select jsonb_agg(jsonb_build_object(
      'nom', rolname, 'bypassrls', rolbypassrls, 'superuser', rolsuper,
      'login', rolcanlogin, 'membre_de',
      (select coalesce(jsonb_agg(g.rolname), '[]'::jsonb) from pg_auth_members m
        join pg_roles g on g.oid = m.roleid where m.member = r.oid)) order by rolname)
      from pg_roles r where rolname not like 'pg\\_%'"),

  "schemas": $(j "
    select jsonb_agg(jsonb_build_object('nom', nspname,
      'tables', (select count(*) from pg_tables where schemaname = nspname)) order by nspname)
      from pg_namespace
     where nspname not like 'pg\\_%' and nspname <> 'information_schema'"),

  "tables": $(j "
    select jsonb_agg(jsonb_build_object(
      'nom', schemaname || '.' || tablename,
      'lignes', (select reltuples::bigint from pg_class c join pg_namespace n on n.oid=c.relnamespace
                  where n.nspname=schemaname and c.relname=tablename),
      'taille', pg_size_pretty(pg_total_relation_size((quote_ident(schemaname)||'.'||quote_ident(tablename))::regclass)),
      'taille_octets', pg_total_relation_size((quote_ident(schemaname)||'.'||quote_ident(tablename))::regclass),
      'rls', (select relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
               where n.nspname=schemaname and c.relname=tablename),
      'force_rls', (select relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
                     where n.nspname=schemaname and c.relname=tablename))
      order by pg_total_relation_size((quote_ident(schemaname)||'.'||quote_ident(tablename))::regclass) desc)
      from pg_tables where schemaname not in ('pg_catalog','information_schema')"),

  "policies": $(j "
    select jsonb_build_object('total', sum(n), 'par_schema', jsonb_object_agg(schemaname, n))
      from (select schemaname, count(*) n from pg_policies
             where schemaname not in ('pg_catalog') group by schemaname) s"),

  "index_vectoriels": $(j "
    select jsonb_agg(jsonb_build_object('nom', indexname, 'table', schemaname||'.'||tablename,
      'definition', indexdef,
      'taille', pg_size_pretty(pg_relation_size((quote_ident(schemaname)||'.'||quote_ident(indexname))::regclass))))
      from pg_indexes where indexdef ~* 'ivfflat|hnsw'"),

  "jobs_cron": $(j "
    select jsonb_agg(jsonb_build_object('nom', jobname, 'planification', schedule,
      'actif', active, 'commande', left(command, 200)) order by jobname) from cron.job"),

  "secrets_vault": $(j "
    select jsonb_agg(jsonb_build_object('nom', name, 'longueur', length(coalesce(decrypted_secret,'')))
      order by name) from vault.decrypted_secrets"),

  "buckets": $(j "
    select jsonb_agg(jsonb_build_object('id', id, 'public', public,
      'limite_octets', file_size_limit, 'types_mime', allowed_mime_types,
      'objets', (select count(*) from storage.objects o where o.bucket_id = b.id),
      'volume_octets', (select coalesce(sum((metadata->>'size')::bigint),0) from storage.objects o where o.bucket_id = b.id))
      order by id) from storage.buckets b"),

  "realtime": $(j "
    select jsonb_build_object('publication', pubname,
      'tables', jsonb_agg(schemaname||'.'||tablename order by tablename))
      from pg_publication_tables where pubname = 'supabase_realtime' group by pubname"),

  "webhooks": $(j "
    select jsonb_build_object(
      'schema_supabase_functions', exists(select 1 from pg_namespace where nspname='supabase_functions'),
      'triggers', (select coalesce(jsonb_agg(jsonb_build_object('nom', tgname, 'table', tgrelid::regclass::text)), '[]'::jsonb)
                     from pg_trigger t
                    where not tgisinternal
                      and pg_get_triggerdef(t.oid) ilike '%supabase_functions.http_request%'))"),

  "auth": $(j "
    select jsonb_build_object(
      'utilisateurs', (select count(*) from auth.users),
      'sessions', (select count(*) from auth.sessions),
      'jetons_rafraichissement', (select count(*) from auth.refresh_tokens),
      'facteurs_mfa', (select count(*) from auth.mfa_factors),
      'identites', (select count(*) from auth.identities),
      'anonymes', (select count(*) from auth.users where is_anonymous))"),

  "appels_sortants_recents": $(j "
    select jsonb_build_object('reponses', count(*),
      'derniers_codes', jsonb_agg(distinct status_code)) from net._http_response"),

  "fonctions_security_definer": $(j "
    select jsonb_agg(jsonb_build_object('nom', n.nspname||'.'||p.proname,
      'search_path_fige', (p.proconfig is not null)) order by n.nspname, p.proname)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.prosecdef and n.nspname not in ('pg_catalog','information_schema')")
}
JSON
