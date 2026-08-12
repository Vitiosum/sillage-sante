// Genere le PDF d'une ordonnance, le depose sur le Storage et enregistre
// son empreinte. Appelee depuis le front par le praticien (verify_jwt = true).
import { clientUtilisateur, clientAdmin } from '../_shared/supabase.ts';
import { reponseJson, enTetesCors } from '../_shared/cors.ts';
import { PDFDocument, StandardFonts } from 'https://esm.sh/pdf-lib@1.17.1';
import { encodeHex } from 'https://deno.land/std@0.224.0/encoding/hex.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: enTetesCors });

  const { ordonnance_id } = await req.json();
  if (!ordonnance_id) return reponseJson({ erreur: 'ordonnance_id requis' }, 400);

  // Lecture sous l'identite de l'appelant : la RLS verifie que c'est bien
  // le prescripteur.
  const utilisateur = clientUtilisateur(req);
  const { data: ordonnance, error } = await utilisateur
    .schema('medical')
    .from('ordonnances')
    .select('id, lignes, consultations(patient_id, praticien_id, cree_a)')
    .eq('id', ordonnance_id)
    .single();

  if (error || !ordonnance) return reponseJson({ erreur: 'Ordonnance introuvable' }, 404);

  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const police = await pdf.embedFont(StandardFonts.Helvetica);

  page.drawText('ORDONNANCE', { x: 50, y: 780, size: 18, font: police });
  let y = 720;
  for (const ligne of ordonnance.lignes as Array<Record<string, string>>) {
    page.drawText(`- ${ligne.medicament} — ${ligne.posologie}`, { x: 50, y, size: 11, font: police });
    y -= 20;
  }

  const octets = await pdf.save();
  const empreinte = encodeHex(new Uint8Array(await crypto.subtle.digest('SHA-256', octets)));

  const patientId = (ordonnance as any).consultations.patient_id;
  const chemin = `${patientId}/${ordonnance_id}.pdf`;

  // Depot avec service_role : le bucket n'a pas de policy INSERT pour ce cas
  const admin = clientAdmin();
  const { error: erreurUpload } = await admin.storage
    .from('ordonnances')
    .upload(chemin, octets, { contentType: 'application/pdf', upsert: true });

  if (erreurUpload) return reponseJson({ erreur: erreurUpload.message }, 500);

  await admin.schema('medical').from('ordonnances')
    .update({ pdf_chemin: chemin, empreinte_sha256: empreinte, signee_a: new Date().toISOString() })
    .eq('id', ordonnance_id);

  const { data: lien } = await admin.storage
    .from('ordonnances')
    .createSignedUrl(chemin, 900);

  return reponseJson({ chemin, empreinte, url_signee: lien?.signedUrl });
});
