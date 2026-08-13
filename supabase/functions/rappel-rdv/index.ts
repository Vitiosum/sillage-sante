// Rappel de rendez-vous, invoque toutes les heures par pg_cron.
// Cherche les RDV a moins de 24 h dont le rappel n'a pas encore ete envoye.
import { clientAdmin } from '../_shared/supabase.ts';
import { reponseJson, enTetesCors } from '../_shared/cors.ts';

const BREVO_API_KEY = Deno.env.get('BREVO_API_KEY')!;
const BREVO_SENDER = Deno.env.get('BREVO_SENDER') ?? 'no-reply@sillage-sante.example';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: enTetesCors });

  const supabase = clientAdmin();

  // medical.rendez_vous.creneau est un tstzrange (contrainte d'exclusion gist
  // sur l'agenda), pas un timestamp : on selectionne les rendez-vous qui
  // chevauchent les 24 prochaines heures, ce qui ecarte aussi le passe.
  const maintenant = new Date();
  const dans24h = new Date(maintenant.getTime() + 24 * 3600 * 1000);

  // .schema() se pose sur le client, avant .from() : en fin de chaine c'est
  // un PostgrestFilterBuilder, qui n'a pas cette methode -> TypeError, 500.
  const { data: rdvs, error } = await supabase
    .schema('medical')
    .from('rendez_vous')
    .select('id, creneau, teleconsultation, patients(prenom, nom_naissance, profils(id, telephone)), praticiens(specialite, profils(nom))')
    .eq('statut', 'confirme')
    .is('rappel_envoye_a', null)
    .overlaps('creneau', `[${maintenant.toISOString()},${dans24h.toISOString()})`);

  if (error) return reponseJson({ erreur: error.message }, 500);

  let envoyes = 0;

  for (const rdv of rdvs ?? []) {
    const destinataire = (rdv as any).patients?.profils;
    if (!destinataire) continue;

    const { data: user } = await supabase.auth.admin.getUserById(destinataire.id);
    if (!user?.user?.email) continue;

    const reponse = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': BREVO_API_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sender: { email: BREVO_SENDER, name: 'Sillage Sante' },
        to: [{ email: user.user.email }],
        subject: 'Rappel de votre rendez-vous',
        htmlContent: `<p>Bonjour,</p><p>Votre rendez-vous est prevu demain.</p>`,
      }),
    });

    // Trace applicative, lue par le patient dans son espace
    await supabase.schema('medical').from('notifications').insert({
      destinataire_id: destinataire.id,
      canal: 'email',
      sujet: 'Rappel de rendez-vous',
      corps: 'Votre rendez-vous est prevu demain.',
      envoyee_a: reponse.ok ? new Date().toISOString() : null,
      erreur: reponse.ok ? null : await reponse.text(),
    });

    if (reponse.ok) {
      await supabase.schema('medical').from('rendez_vous')
        .update({ rappel_envoye_a: new Date().toISOString() })
        .eq('id', rdv.id);
      envoyes++;
    }
  }

  return reponseJson({ traites: rdvs?.length ?? 0, envoyes });
});
