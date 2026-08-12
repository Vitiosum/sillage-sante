'use client';

import { useEffect, useRef, useState } from 'react';
import type { RealtimeChannel } from '@supabase/supabase-js';
import { creerClientNavigateur } from '@/lib/supabase/client';

type Message = { id: string; corps: string; auteur_id: string; cree_a: string };

export default function Messagerie({ patientId }: { patientId: string }) {
  const supabase = useRef(creerClientNavigateur()).current;
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [brouillon, setBrouillon] = useState('');

  useEffect(() => {
    let canal: RealtimeChannel | undefined;

    (async () => {
      const { data: conversation } = await supabase
        .from('conversations')
        .select('id')
        .eq('patient_id', patientId)
        .maybeSingle();

      if (!conversation) return;
      setConversationId(conversation.id);

      const { data: anciens } = await supabase
        .from('messages')
        .select('id, corps, auteur_id, cree_a')
        .eq('conversation_id', conversation.id)
        .order('cree_a');

      setMessages(anciens ?? []);

      // Flux temps reel : postgres_changes sur medical.messages.
      // Les policies RLS sont evaluees par le serveur Realtime.
      canal = supabase
        .channel(`conversation:${conversation.id}`)
        .on(
          'postgres_changes',
          {
            event: 'INSERT',
            schema: 'medical',
            table: 'messages',
            filter: `conversation_id=eq.${conversation.id}`,
          },
          ({ new: message }) => setMessages((m) => [...m, message as Message]),
        )
        .subscribe();
    })();

    return () => { if (canal) supabase.removeChannel(canal); };
  }, [patientId, supabase]);

  async function envoyer() {
    if (!conversationId || !brouillon.trim()) return;
    const { data: { user } } = await supabase.auth.getUser();
    await supabase.from('messages').insert({
      conversation_id: conversationId,
      auteur_id: user!.id,
      corps: brouillon,
    });
    setBrouillon('');
  }

  return (
    <section>
      <h2>Messagerie securisee</h2>
      {messages.map((m) => (
        <p key={m.id} className="carte">{m.corps}</p>
      ))}
      <textarea
        value={brouillon}
        onChange={(e) => setBrouillon(e.target.value)}
        placeholder="Ecrire un message"
        rows={3}
      />
      <button onClick={envoyer} disabled={!conversationId || !brouillon.trim()}>Envoyer</button>
    </section>
  );
}
