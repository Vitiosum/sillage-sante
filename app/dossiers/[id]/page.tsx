import { creerClientServeur } from '@/lib/supabase/server';
import Messagerie from './messagerie';

export default async function Dossier({ params }: { params: { id: string } }) {
  const supabase = creerClientServeur();

  const [{ data: patient }, { data: consultations }, { data: documents }] = await Promise.all([
    supabase.from('patients').select('*').eq('id', params.id).single(),
    supabase
      .from('consultations')
      .select('id, cree_a, compte_rendu, diagnostic_cim10, cloturee_a')
      .eq('patient_id', params.id)
      .order('cree_a', { ascending: false }),
    supabase
      .from('documents')
      .select('id, nom_affiche, mime, taille_octets, statut_scan, cree_a')
      .eq('patient_id', params.id)
      .eq('statut_scan', 'sain'),
  ]);

  if (!patient) return <p>Dossier introuvable ou acces non autorise.</p>;

  return (
    <>
      <h1>{patient.nom_naissance} {patient.prenom}</h1>

      <section>
        <h2>Consultations</h2>
        {consultations?.map((c) => (
          <article key={c.id} className="carte">
            <p>{new Date(c.cree_a).toLocaleDateString('fr-FR')}</p>
            <p>{c.compte_rendu ?? 'Compte rendu en cours de redaction'}</p>
            {c.diagnostic_cim10?.length ? <p>CIM-10 : {c.diagnostic_cim10.join(', ')}</p> : null}
          </article>
        ))}
      </section>

      <section>
        <h2>Documents</h2>
        {documents?.map((d) => (
          <article key={d.id} className="carte">
            {d.nom_affiche} — {Math.round(d.taille_octets / 1024)} Ko
          </article>
        ))}
      </section>

      <Messagerie patientId={params.id} />
    </>
  );
}
