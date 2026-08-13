-- ---------------------------------------------------------------------------
-- 13. Correctif : droits manquants du hook GoTrue sur le schema medical
-- ---------------------------------------------------------------------------
-- Constate en activant le hook custom_access_token sur le projet de demo
-- (13 aout 2026). 20260114090500_auth_hook_claims.sql accorde bien :
--   - usage sur le schema auth_hooks
--   - execute sur la fonction
--   - select sur profils / praticiens / patients
--   - une policy de lecture sur medical.profils
-- mais il manque deux choses, et la fonction est `stable`, pas
-- `security definer` : elle s'execute donc avec les droits de
-- supabase_auth_admin, qui doit tout posseder explicitement.
--
-- 1. USAGE sur le schema medical. Sans lui, les GRANT SELECT sont
--    inoperants : `permission denied for schema medical`, et GoTrue rend
--    HTTP 500 `unexpected_failure` a CHAQUE emission de jeton. Plus aucune
--    connexion possible, ni patient ni praticien.
--
-- 2. Les policies de lecture sur medical.praticiens et medical.patients.
--    RLS y est active (20260114090400_rls.sql l.12-13) et seule profils
--    avait sa policy : les deux `select ... into` du hook renvoyaient zero
--    ligne en silence, donc praticien_id et patient_id absents du JWT.
--    Consequence : medical.praticien_courant() et patient_courant() nuls,
--    et la moitie des policies RLS renvoie vide sans erreur.
--
-- Ni profils ni praticiens ni patients ne sont en `force row level
-- security` (seules consultations et documents le sont), donc une policy
-- `using (true)` restreinte au role supabase_auth_admin suffit.
--
-- Portee : lecture seule, reservee au role GoTrue. Ces policies ne sont
-- evaluees que pour supabase_auth_admin, jamais pour anon ni authenticated.
-- ---------------------------------------------------------------------------

grant usage on schema medical to supabase_auth_admin;

do $$
begin
  create policy "lecture praticiens par le hook GoTrue"
    on medical.praticiens for select to supabase_auth_admin using (true);
exception when duplicate_object then
  null;
end
$$;

do $$
begin
  create policy "lecture patients par le hook GoTrue"
    on medical.patients for select to supabase_auth_admin using (true);
exception when duplicate_object then
  null;
end
$$;

-- Controle : les trois doivent renvoyer true.
do $$
begin
  if not has_schema_privilege('supabase_auth_admin', 'medical', 'usage') then
    raise exception 'supabase_auth_admin n''a toujours pas USAGE sur medical';
  end if;
  if not has_table_privilege('supabase_auth_admin', 'medical.praticiens', 'select') then
    raise exception 'supabase_auth_admin n''a pas SELECT sur medical.praticiens';
  end if;
  if not has_table_privilege('supabase_auth_admin', 'medical.patients', 'select') then
    raise exception 'supabase_auth_admin n''a pas SELECT sur medical.patients';
  end if;
end
$$;
