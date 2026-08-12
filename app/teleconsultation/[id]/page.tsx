'use client';

import { useEffect, useRef, useState } from 'react';
import { creerClientNavigateur } from '@/lib/supabase/client';

/**
 * Salle de teleconsultation.
 * Realtime sert ici a deux choses : Presence pour savoir qui est dans la
 * salle, Broadcast pour la signalisation WebRTC (offre / reponse / ICE).
 */
export default function Salle({ params }: { params: { id: string } }) {
  const supabase = useRef(creerClientNavigateur()).current;
  const [presents, setPresents] = useState<string[]>([]);
  const [etat, setEtat] = useState('connexion');

  useEffect(() => {
    const canal = supabase.channel(`teleconsultation:${params.id}`, {
      config: { presence: { key: crypto.randomUUID() }, broadcast: { ack: true } },
    });

    canal
      .on('presence', { event: 'sync' }, () => {
        const etatPresence = canal.presenceState<{ role: string }>();
        setPresents(Object.values(etatPresence).flat().map((p) => p.role));
      })
      .on('broadcast', { event: 'signal-webrtc' }, ({ payload }) => {
        // Transmis au RTCPeerConnection : offre, reponse ou candidat ICE
        console.debug('signalisation', payload.type);
      })
      .subscribe(async (statut) => {
        if (statut !== 'SUBSCRIBED') return;
        const { data: { user } } = await supabase.auth.getUser();
        await canal.track({ role: user?.app_metadata?.role_metier ?? 'patient' });
        setEtat('en salle');
      });

    return () => { supabase.removeChannel(canal); };
  }, [params.id, supabase]);

  return (
    <>
      <h1>Teleconsultation</h1>
      <p>Etat : {etat}</p>
      <p>Dans la salle : {presents.join(', ') || 'personne pour l\'instant'}</p>
    </>
  );
}
