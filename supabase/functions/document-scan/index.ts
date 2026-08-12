// Webhook appele par l'antivirus apres analyse d'un document.
// verify_jwt = false : l'authenticite est verifiee par signature HMAC.
import { clientAdmin } from '../_shared/supabase.ts';
import { reponseJson } from '../_shared/cors.ts';

const SECRET = Deno.env.get('ANTIVIRUS_WEBHOOK_TOKEN')!;

async function signatureValide(corps: string, entete: string | null): Promise<boolean> {
  if (!entete) return false;
  const cle = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(SECRET),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const attendu = await crypto.subtle.sign('HMAC', cle, new TextEncoder().encode(corps));
  const attenduHex = Array.from(new Uint8Array(attendu))
    .map((o) => o.toString(16).padStart(2, '0')).join('');
  return attenduHex === entete;
}

Deno.serve(async (req) => {
  const corps = await req.text();

  if (!(await signatureValide(corps, req.headers.get('x-signature')))) {
    return reponseJson({ erreur: 'Signature invalide' }, 401);
  }

  const { document_id, verdict } = JSON.parse(corps) as {
    document_id: string;
    verdict: 'sain' | 'infecte' | 'erreur';
  };

  const supabase = clientAdmin();

  const { error } = await supabase
    .schema('medical')
    .from('documents')
    .update({ statut_scan: verdict })
    .eq('id', document_id);

  if (error) return reponseJson({ erreur: error.message }, 500);

  // Un document infecte est retire du Storage sans attendre le batch de nuit
  if (verdict === 'infecte') {
    const { data: doc } = await supabase
      .schema('medical').from('documents')
      .select('bucket, chemin').eq('id', document_id).single();
    if (doc) await supabase.storage.from(doc.bucket).remove([doc.chemin]);
  }

  return reponseJson({ document_id, verdict });
});
