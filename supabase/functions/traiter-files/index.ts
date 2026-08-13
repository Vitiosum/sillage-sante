// Consomme les files pgmq (Supabase Queues).
// Invoquee toutes les 5 minutes par pg_cron.
import { clientAdmin } from '../_shared/supabase.ts';
import { reponseJson } from '../_shared/cors.ts';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');

async function recalculerEmbedding(supabase: ReturnType<typeof clientAdmin>, id: string) {
  const { data: consultation } = await supabase
    .schema('medical').from('consultations')
    .select('compte_rendu').eq('id', id).single();

  if (!consultation?.compte_rendu || !OPENAI_API_KEY) return false;

  const reponse = await fetch('https://api.openai.com/v1/embeddings', {
    method: 'POST',
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'text-embedding-3-small',
      input: consultation.compte_rendu,
      dimensions: 1536,
    }),
  });
  if (!reponse.ok) return false;

  const { data } = await reponse.json();
  await supabase.schema('medical').from('consultations')
    .update({ embedding: JSON.stringify(data[0].embedding) })
    .eq('id', id);

  return true;
}

Deno.serve(async () => {
  const supabase = clientAdmin();
  const bilan: Record<string, number> = {};

  const { data: messages, error } = await supabase.rpc('lire_file', {
    p_file: 'embeddings_a_recalculer',
    p_lot: 25,
  });

  if (error) return reponseJson({ erreur: error.message }, 500);

  let traites = 0;
  for (const message of messages ?? []) {
    const id = (message as { consultation_id: string }).consultation_id;
    if (await recalculerEmbedding(supabase, id)) traites++;
  }
  bilan.embeddings = traites;

  return reponseJson(bilan);
});
