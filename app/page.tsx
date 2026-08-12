import { creerClientServeur } from '@/lib/supabase/server';

export default async function Accueil() {
  const supabase = creerClientServeur();

  // Annuaire public : lisible par le role anon grace a la policy
  // "praticiens actifs consultables par tous"
  const { data: praticiens } = await supabase
    .from('praticiens')
    .select('id, specialite, secteur, cabinets(raison_sociale, ville)')
    .eq('actif', true)
    .limit(20);

  return (
    <>
      <h1>Prendre rendez-vous</h1>
      {praticiens?.map((p) => (
        <article key={p.id} className="carte">
          <h2>{p.specialite}</h2>
          <p>
            {(p as any).cabinets?.raison_sociale} — {(p as any).cabinets?.ville}
            {' · '}secteur {p.secteur}
          </p>
          <a href={`/rendez-vous/${p.id}`}>Voir les creneaux</a>
        </article>
      ))}
    </>
  );
}
