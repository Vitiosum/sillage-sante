'use client';

import { useState } from 'react';
import { creerClientNavigateur } from '@/lib/supabase/client';
import { chiffrer, empreinte } from '@/lib/chiffrement';

export default function Documents() {
  const supabase = creerClientNavigateur();
  const [etat, setEtat] = useState<'pret' | 'envoi' | 'ok' | 'erreur'>('pret');
  const [message, setMessage] = useState('');

  async function televerser(fichier: File, patientId: string) {
    setEtat('envoi');

    const octets = await fichier.arrayBuffer();
    const somme = await empreinte(octets);
    const paquet = await chiffrer(octets);

    const chemin = `${patientId}/${new Date().getFullYear()}/${crypto.randomUUID()}.enc`;

    // Le bucket est prive : la policy verifie que le premier segment du
    // chemin correspond a un dossier auquel l'appelant a acces.
    const { error: erreurUpload } = await supabase.storage
      .from('documents-medicaux')
      .upload(chemin, paquet, { contentType: 'application/octet-stream', upsert: false });

    if (erreurUpload) { setEtat('erreur'); setMessage(erreurUpload.message); return; }

    const { data: { user } } = await supabase.auth.getUser();

    // L'insertion declenche le trigger pg_net qui envoie le document a l'antivirus.
    const { error } = await supabase.from('documents').insert({
      patient_id: patientId,
      deposant_id: user!.id,
      chemin,
      nom_affiche: fichier.name,
      mime: fichier.type,
      taille_octets: fichier.size,
      chiffre: true,
    });

    if (error) { setEtat('erreur'); setMessage(error.message); return; }
    setEtat('ok');
    setMessage(`Depose. Empreinte ${somme.slice(0, 12)}. Analyse antivirus en cours.`);
  }

  async function telecharger(bucket: string, chemin: string) {
    // Bucket prive : on passe par une URL signee a duree courte
    const { data, error } = await supabase.storage.from(bucket).createSignedUrl(chemin, 300);
    if (error) { setMessage(error.message); return; }
    window.open(data.signedUrl, '_blank', 'noopener');
  }

  return (
    <>
      <h1>Deposer un document</h1>
      <div className="carte">
        <input
          type="file"
          accept="application/pdf,image/png,image/jpeg"
          onChange={(e) => {
            const fichier = e.target.files?.[0];
            const patientId = new URLSearchParams(location.search).get('patient');
            if (fichier && patientId) televerser(fichier, patientId);
          }}
        />
        <p>Le document est chiffre sur votre appareil avant l&apos;envoi.</p>
        {etat === 'envoi' && <p>Chiffrement et envoi en cours…</p>}
        {message && <p role="status">{message}</p>}
      </div>
    </>
  );
}
