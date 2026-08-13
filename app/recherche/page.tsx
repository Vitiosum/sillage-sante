'use client';

import { useState } from 'react';
import { creerClientNavigateur } from '@/lib/supabase/client';

type Resultat = {
  praticien_id: string;
  specialite: string;
  cabinet: string;
  ville: string;
  distance_km: number;
};

export default function Recherche() {
  const supabase = creerClientNavigateur();
  const [resultats, setResultats] = useState<Resultat[]>([]);
  const [specialite, setSpecialite] = useState('');
  const [etat, setEtat] = useState<'pret' | 'localisation' | 'recherche' | 'erreur'>('pret');
  const [message, setMessage] = useState('');

  function chercherAutourDeMoi() {
    setEtat('localisation');

    navigator.geolocation.getCurrentPosition(
      async ({ coords }) => {
        setEtat('recherche');

        // RPC PostGIS : st_dwithin sur un index gist
        const { data, error } = await supabase.rpc('praticiens_a_proximite', {
          p_latitude: coords.latitude,
          p_longitude: coords.longitude,
          p_rayon_km: 15,
          p_specialite: specialite || null,
        });

        if (error) { setEtat('erreur'); setMessage(error.message); return; }
        setResultats(data ?? []);
        setEtat('pret');
      },
      () => {
        setEtat('erreur');
        setMessage('Position indisponible. Saisissez une ville pour chercher.');
      },
    );
  }

  return (
    <>
      <h1>Trouver un praticien</h1>

      <div className="carte">
        <label htmlFor="specialite">Spécialité</label>
        <input
          id="specialite"
          value={specialite}
          onChange={(e) => setSpecialite(e.target.value)}
          placeholder="Médecine générale, kinésithérapie…"
        />
        <p>
          <button onClick={chercherAutourDeMoi} disabled={etat === 'localisation' || etat === 'recherche'}>
            Chercher autour de moi
          </button>
        </p>
        {etat === 'localisation' && <p>Localisation en cours…</p>}
        {etat === 'erreur' && <p role="alert">{message}</p>}
      </div>

      {resultats.map((r) => (
        <article key={r.praticien_id} className="carte">
          <h2>{r.specialite}</h2>
          <p>{r.cabinet} — {r.ville} · {r.distance_km} km</p>
          <a href={`/rendez-vous/${r.praticien_id}`}>Voir les créneaux</a>
        </article>
      ))}
    </>
  );
}
