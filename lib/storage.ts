import { creerClientNavigateur } from '@/lib/supabase/client';

/**
 * URL d'avatar redimensionnee a la volee par le Storage (imgproxy).
 * Fonctionnalite propre au Storage Supabase : un S3 nu ne sait pas faire ca.
 */
export function urlAvatar(userId: string, taille = 96): string {
  const supabase = creerClientNavigateur();
  const { data } = supabase.storage.from('avatars').getPublicUrl(`${userId}/avatar.webp`, {
    transform: { width: taille, height: taille, resize: 'cover', quality: 80 },
  });
  return data.publicUrl;
}

/** URL signee avec transformation, pour les apercus de documents prives. */
export async function apercuDocument(chemin: string, largeur = 400) {
  const supabase = creerClientNavigateur();
  const { data, error } = await supabase.storage
    .from('documents-medicaux')
    .createSignedUrl(chemin, 300, { transform: { width: largeur, resize: 'contain' } });
  if (error) throw error;
  return data.signedUrl;
}

/**
 * Televersement reprenable (protocole TUS) pour les series DICOM, qui
 * depassent largement la limite d'un upload standard.
 */
export async function televerserImagerie(
  fichier: File,
  patientId: string,
  surProgression: (pourcent: number) => void,
) {
  const supabase = creerClientNavigateur();
  const { data: { session } } = await supabase.auth.getSession();

  const chemin = `${patientId}/${crypto.randomUUID()}-${fichier.name}`;

  const { data: suivi } = await supabase.from('televersements').insert({
    patient_id: patientId,
    deposant_id: session!.user.id,
    chemin_cible: chemin,
    octets_total: fichier.size,
  }).select('id').single();

  const { Upload } = await import('tus-js-client');

  return new Promise<string>((resoudre, rejeter) => {
    const envoi = new Upload(fichier, {
      endpoint: `${process.env.NEXT_PUBLIC_SUPABASE_URL}/storage/v1/upload/resumable`,
      retryDelays: [0, 3000, 5000, 10000, 20000],
      headers: {
        authorization: `Bearer ${session!.access_token}`,
        'x-upsert': 'false',
      },
      uploadDataDuringCreation: true,
      removeFingerprintOnSuccess: true,
      chunkSize: 6 * 1024 * 1024, // impose par le Storage Supabase
      metadata: {
        bucketName: 'imagerie',
        objectName: chemin,
        contentType: fichier.type,
      },
      onProgress: (envoyes, total) => {
        surProgression(Math.round((envoyes / total) * 100));
        supabase.from('televersements')
          .update({ octets_recus: envoyes })
          .eq('id', suivi!.id);
      },
      onSuccess: async () => {
        await supabase.from('televersements')
          .update({ termine_a: new Date().toISOString(), octets_recus: fichier.size })
          .eq('id', suivi!.id);
        resoudre(chemin);
      },
      onError: rejeter,
    });

    envoi.start();
  });
}
