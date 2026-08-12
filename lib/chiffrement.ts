/**
 * Chiffrement applicatif des documents medicaux avant depot sur le Storage.
 * AES-256-GCM, cle fournie par l'environnement (jamais persistee en base).
 */
const KEY_B64 = process.env.DOCUMENTS_ENCRYPTION_KEY!;

async function cle(): Promise<CryptoKey> {
  const brut = Uint8Array.from(atob(KEY_B64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey('raw', brut, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

export async function chiffrer(donnees: ArrayBuffer): Promise<Blob> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const chiffre = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await cle(), donnees);
  // Format : [12 octets IV][texte chiffre]
  return new Blob([iv, new Uint8Array(chiffre)], { type: 'application/octet-stream' });
}

export async function dechiffrer(paquet: ArrayBuffer): Promise<ArrayBuffer> {
  const iv = new Uint8Array(paquet.slice(0, 12));
  const corps = paquet.slice(12);
  return crypto.subtle.decrypt({ name: 'AES-GCM', iv }, await cle(), corps);
}

export async function empreinte(donnees: ArrayBuffer): Promise<string> {
  const somme = await crypto.subtle.digest('SHA-256', donnees);
  return Array.from(new Uint8Array(somme))
    .map((o) => o.toString(16).padStart(2, '0'))
    .join('');
}
