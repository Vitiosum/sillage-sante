import { creerClientServeur } from '@/lib/supabase/server';

export default async function ListeDossiers() {
  const supabase = creerClientServeur();

  // La RLS fait le tri : un praticien voit ses prises en charge,
  // un patient ne voit que son propre dossier.
  const { data: patients, error } = await supabase
    .from('patients')
    .select('id, nom_naissance, prenom, date_naissance, prises_en_charge(debut, fin)')
    .order('nom_naissance');

  if (error) {
    return <p role="alert">Impossible de charger les dossiers : {error.message}</p>;
  }

  if (!patients?.length) {
    return <p>Aucun dossier. Les dossiers apparaissent des la premiere prise en charge.</p>;
  }

  return (
    <>
      <h1>Dossiers</h1>
      {patients.map((p) => (
        <article key={p.id} className="carte">
          <h2>{p.nom_naissance} {p.prenom}</h2>
          <p>Ne(e) le {new Date(p.date_naissance).toLocaleDateString('fr-FR')}</p>
          <a href={`/dossiers/${p.id}`}>Ouvrir le dossier</a>
        </article>
      ))}
    </>
  );
}
