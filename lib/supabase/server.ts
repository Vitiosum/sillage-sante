import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

/** Client serveur, session portee par les cookies. */
export function creerClientServeur() {
  const magasin = cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      db: { schema: 'medical' },
      cookies: {
        getAll: () => magasin.getAll(),
        setAll: (cookiesAPoser) => {
          try {
            cookiesAPoser.forEach(({ name, value, options }) =>
              magasin.set(name, value, options),
            );
          } catch {
            // Appel depuis un Server Component : le middleware rafraichit la session.
          }
        },
      },
    },
  );
}
