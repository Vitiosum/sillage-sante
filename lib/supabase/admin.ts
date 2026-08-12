import { createClient } from '@supabase/supabase-js';

/**
 * Client service_role. Contourne la RLS : ne jamais l'importer depuis un
 * composant client, ni exposer la cle via une variable NEXT_PUBLIC_.
 */
export function creerClientAdmin() {
  if (typeof window !== 'undefined') {
    throw new Error('creerClientAdmin() est reserve au serveur');
  }

  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      db: { schema: 'medical' },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
}
