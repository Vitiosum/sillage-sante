'use client';

import { useState } from 'react';
import { creerClientNavigateur } from '@/lib/supabase/client';

export default function Connexion() {
  const supabase = creerClientNavigateur();
  const [email, setEmail] = useState('');
  const [etat, setEtat] = useState<'saisie' | 'envoi' | 'envoye' | 'erreur'>('saisie');
  const [message, setMessage] = useState('');

  async function envoyerLienMagique() {
    setEtat('envoi');
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${process.env.NEXT_PUBLIC_SITE_URL}/auth/callback`,
        shouldCreateUser: true,
        data: { role_metier: 'patient' },
      },
    });
    if (error) { setEtat('erreur'); setMessage(error.message); return; }
    setEtat('envoye');
  }

  async function connexionProSante() {
    // Fournisseur d'identite des professionnels de sante (OIDC via GoTrue)
    await supabase.auth.signInWithOAuth({
      provider: 'keycloak',
      options: {
        scopes: 'openid profile',
        redirectTo: `${process.env.NEXT_PUBLIC_SITE_URL}/auth/callback`,
      },
    });
  }

  if (etat === 'envoye') {
    return <p>Lien envoye a {email}. Ouvrez-le depuis cet appareil pour vous connecter.</p>;
  }

  return (
    <>
      <h1>Se connecter</h1>

      <div className="carte">
        <label htmlFor="email">Adresse e-mail</label>
        <input id="email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <p>
          <button onClick={envoyerLienMagique} disabled={etat === 'envoi' || !email}>
            Recevoir un lien de connexion
          </button>
        </p>
        {etat === 'erreur' && <p role="alert">{message}</p>}
      </div>

      <div className="carte">
        <p>Vous etes professionnel de sante ?</p>
        <button onClick={connexionProSante}>Se connecter avec son identite professionnelle</button>
      </div>
    </>
  );
}
