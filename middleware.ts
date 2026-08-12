import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

const CHEMINS_PUBLICS = ['/', '/connexion', '/auth/callback', '/annuaire'];

export async function middleware(request: NextRequest) {
  let reponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookies) => {
          cookies.forEach(({ name, value }) => request.cookies.set(name, value));
          reponse = NextResponse.next({ request });
          cookies.forEach(({ name, value, options }) => reponse.cookies.set(name, value, options));
        },
      },
    },
  );

  // Rafraichit la session GoTrue a chaque navigation
  const { data: { user } } = await supabase.auth.getUser();
  const chemin = request.nextUrl.pathname;

  if (!user && !CHEMINS_PUBLICS.some((p) => chemin === p || chemin.startsWith(p + '/'))) {
    const url = request.nextUrl.clone();
    url.pathname = '/connexion';
    url.searchParams.set('suite', chemin);
    return NextResponse.redirect(url);
  }

  // Le contenu medical exige un second facteur (aal2)
  if (user && chemin.startsWith('/dossiers')) {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal?.nextLevel === 'aal2' && aal.nextLevel !== aal.currentLevel) {
      const url = request.nextUrl.clone();
      url.pathname = '/connexion/second-facteur';
      return NextResponse.redirect(url);
    }
  }

  return reponse;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|webp)$).*)'],
};
