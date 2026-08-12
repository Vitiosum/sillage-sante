import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

/** Client service_role : contourne la RLS, reserve aux traitements machine. */
export function clientAdmin(): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

/** Client agissant au nom de l'appelant : la RLS s'applique. */
export function clientUtilisateur(req: Request): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
      auth: { persistSession: false },
    },
  );
}
