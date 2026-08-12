// Recherche semantique dans les comptes rendus du praticien connecte.
// Calcule l'embedding de la requete puis delegue le rapprochement a pgvector.
import { clientUtilisateur } from '../_shared/supabase.ts';
import { reponseJson, enTetesCors } from '../_shared/cors.ts';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY')!;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: enTetesCors });

  const { requete, seuil = 0.78, limite = 10 } = await req.json();
  if (!requete) return reponseJson({ erreur: 'requete requise' }, 400);

  const reponse = await fetch('https://api.openai.com/v1/embeddings', {
    method: 'POST',
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'text-embedding-3-small', input: requete, dimensions: 1536 }),
  });

  if (!reponse.ok) return reponseJson({ erreur: 'Echec du calcul d\'embedding' }, 502);

  const { data } = await reponse.json();
  const embedding = data[0].embedding as number[];

  // La RLS s'applique : le praticien ne voit que ses propres consultations
  const supabase = clientUtilisateur(req);
  const { data: resultats, error } = await supabase.rpc('consultations_similaires', {
    p_embedding: JSON.stringify(embedding),
    p_seuil: seuil,
    p_limite: limite,
  });

  if (error) return reponseJson({ erreur: error.message }, 500);
  return reponseJson({ resultats });
});
