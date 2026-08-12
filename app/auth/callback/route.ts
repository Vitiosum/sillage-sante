import { NextResponse, type NextRequest } from 'next/server';
import { creerClientServeur } from '@/lib/supabase/server';

/** Echange le code PKCE contre une session GoTrue. */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get('code');
  const suite = searchParams.get('suite') ?? '/dossiers';

  if (code) {
    const supabase = creerClientServeur();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(`${origin}${suite}`);
  }

  return NextResponse.redirect(`${origin}/connexion?erreur=lien_invalide`);
}
