-- ---------------------------------------------------------------------------
-- 06. Hook GoTrue : claims metier dans l'access token
-- ---------------------------------------------------------------------------
-- Declare cote plateforme dans config.toml :
--   [auth.hook.custom_access_token]
--   uri = "pg-functions://postgres/auth_hooks/custom_access_token"
-- ---------------------------------------------------------------------------

create or replace function auth_hooks.custom_access_token(event jsonb)
returns jsonb
language plpgsql stable
set search_path = auth_hooks, medical, public
as $$
declare
  v_claims      jsonb;
  v_user_id     uuid;
  v_role        medical.role_metier;
  v_praticien   uuid;
  v_patient     uuid;
  v_cabinet     uuid;
begin
  v_user_id := (event ->> 'user_id')::uuid;
  v_claims  := event -> 'claims';

  select p.role_metier into v_role
  from medical.profils p where p.id = v_user_id;

  select pr.id, pr.cabinet_id into v_praticien, v_cabinet
  from medical.praticiens pr where pr.profil_id = v_user_id and pr.actif;

  select pa.id into v_patient
  from medical.patients pa where pa.profil_id = v_user_id;

  v_claims := jsonb_set(
    v_claims,
    '{app_metadata}',
    coalesce(v_claims -> 'app_metadata', '{}'::jsonb)
      || jsonb_build_object(
           'role_metier',  coalesce(v_role::text, 'patient'),
           'praticien_id', v_praticien,
           'patient_id',   v_patient,
           'cabinet_id',   v_cabinet
         )
  );

  return jsonb_set(event, '{claims}', v_claims);
end;
$$;

grant usage on schema auth_hooks to supabase_auth_admin;
grant execute on function auth_hooks.custom_access_token(jsonb) to supabase_auth_admin;
revoke execute on function auth_hooks.custom_access_token(jsonb) from authenticated, anon, public;

grant select on medical.profils, medical.praticiens, medical.patients to supabase_auth_admin;

create policy "lecture par le hook GoTrue"
  on medical.profils for select to supabase_auth_admin using (true);
