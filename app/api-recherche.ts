import { creerClientNavigateur } from '@/lib/supabase/client';

/** Appelle l'Edge Function de recherche semantique. */
export async function rechercherComptesRendus(requete: string) {
  const supabase = creerClientNavigateur();

  const { data, error } = await supabase.functions.invoke('recherche-semantique', {
    body: { requete, seuil: 0.8, limite: 15 },
  });

  if (error) throw error;
  return data.resultats as Array<{ id: string; compte_rendu: string; similarite: number }>;
}

/** Reserve un creneau via la RPC PostgREST. */
export async function reserver(praticienId: string, debut: Date, motif: string) {
  const supabase = creerClientNavigateur();

  const { data, error } = await supabase.rpc('reserver_creneau', {
    p_praticien_id: praticienId,
    p_debut: debut.toISOString(),
    p_duree_minutes: 30,
    p_motif: motif,
    p_teleconsultation: true,
  });

  if (error) throw error;
  return data;
}

/** Recherche plein texte, executee cote base. */
export async function chercherTexte(requete: string) {
  const supabase = creerClientNavigateur();
  const { data, error } = await supabase.rpc('rechercher_comptes_rendus', { p_requete: requete });
  if (error) throw error;
  return data;
}
