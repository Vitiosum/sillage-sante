// ---------------------------------------------------------------------------
// Stockage objet — Cellar remplace Supabase Storage.
//
// Cellar est compatible S3 : vos URL pré-signées fonctionnent avec les SDK
// standards. Deux différences qui comptent.
//
// 1. CELLAR_ADDON_HOST est un NOM D'HÔTE NU, sans schéma. Le passer tel quel
//    comme endpoint échoue de façon peu explicite. Il faut préfixer https://
//    soi-même — c'est le piège n°1 de la migration Storage.
//
// 2. Cellar n'a pas de policies par ligne. Le contrôle d'accès aux objets,
//    que Supabase faisait dans storage.objects avec de la RLS, remonte ici
//    dans l'application. Et une clé donne accès à TOUS les buckets de
//    l'add-on : pour cloisonner, créez un second add-on et posez une bucket
//    policy.
// ---------------------------------------------------------------------------
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const hote = process.env.CELLAR_ADDON_HOST;
if (!hote) throw new Error('CELLAR_ADDON_HOST absent : add-on Cellar non lié ?');

export const s3 = new S3Client({
  // Le préfixe https:// est à ajouter : l'add-on injecte un hôte nu.
  endpoint: `https://${hote}`,
  region: 'us-east-1',        // valeur formelle, Cellar ne régionalise pas ainsi
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.CELLAR_ADDON_KEY_ID,
    secretAccessKey: process.env.CELLAR_ADDON_KEY_SECRET,
  },
});

/**
 * URL de téléchargement temporaire.
 *
 * Équivalent de createSignedUrl() de Supabase Storage. Différence de fond :
 * Supabase vérifiait aussi les policies RLS du bucket. Ici, RIEN ne le fait à
 * votre place — vérifiez les droits AVANT de signer.
 */
export async function urlSignee(bucket, chemin, secondes = 60) {
  return getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket, Key: chemin }), {
    expiresIn: secondes,
  });
}

/**
 * Dépôt d'objet.
 *
 * Supabase imposait une liste de types MIME par bucket (allowed_mime_types) et
 * une taille maximale. Cellar ne filtre pas : si ces contraintes comptaient
 * pour vous, elles sont à réimplémenter ici.
 */
export async function deposer(bucket, chemin, corps, typeMime) {
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: chemin,
      Body: corps,
      ContentType: typeMime,
    }),
  );
  return { bucket, chemin };
}
