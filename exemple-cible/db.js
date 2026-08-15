// ---------------------------------------------------------------------------
// Accès base — garder la RLS sans les rôles Supabase.
//
// Chez Supabase, PostgREST se connecte en `authenticator` et endosse `anon` ou
// `authenticated` selon le JWT ; les policies lisent auth.uid().
//
// Un add-on PostgreSQL managé ne permet pas de créer ces rôles par défaut
// (le support peut les ouvrir sur demande). Ce n'est de toute façon pas
// bloquant : la RLS ne dépend pas d'eux, elle dépend d'un contexte lisible en
// SQL. On le pose soi-même, par transaction — aucune demande à faire.
// ---------------------------------------------------------------------------
import pg from 'pg';

// Nom de variable injecté par l'add-on lié. Vérifiez-le avec `clever env`
// plutôt que de le supposer — d'où le repli sur DATABASE_URL.
const chaine = process.env.POSTGRESQL_ADDON_URI || process.env.DATABASE_URL;
if (!chaine) throw new Error('Aucune chaîne de connexion : lancez `clever env`');

// LA RÈGLE QUI CASSE EN PREMIER À L'AUTOSCALING :
//     taille du pool × nombre max d'instances ≤ connexions max du plan.
// Ce chiffre n'est pas publié par plan : demandez-le au support avant de
// relever --max-instances. Un pool de 10 sur 3 instances sature un plan à 25.
export const pool = new pg.Pool({
  connectionString: chaine,
  max: Number(process.env.DB_POOL_MAX || 5),
  idleTimeoutMillis: 30_000,
});

/**
 * Exécute une fonction dans une transaction, avec le contexte utilisateur posé.
 *
 * `set local` est borné à la transaction : le contexte disparaît au COMMIT
 * comme au ROLLBACK. C'est ce qui rend le motif sûr malgré un pool de
 * connexions réutilisées — sans lui, la requête suivante hériterait de
 * l'identité de la précédente.
 *
 * Vos policies Supabase se migrent en remplaçant
 *     auth.uid()
 * par
 *     current_setting('app.utilisateur_id', true)::uuid
 *
 * Le `true` demande à PostgreSQL de renvoyer NULL si le paramètre n'est pas
 * défini, au lieu de lever une erreur : une requête sans contexte ne voit donc
 * rien, au lieu de planter. C'est le comportement qu'on veut.
 */
export async function avecUtilisateur(utilisateurId, travail) {
  const client = await pool.connect();
  try {
    await client.query('begin');
    // set_config(..., true) = équivalent de `set local`, mais paramétrable :
    // jamais d'interpolation de chaîne dans du SQL.
    await client.query("select set_config('app.utilisateur_id', $1, true)", [
      utilisateurId ?? '',
    ]);
    const resultat = await travail(client);
    await client.query('commit');
    return resultat;
  } catch (erreur) {
    await client.query('rollback');
    throw erreur;
  } finally {
    client.release();
  }
}

/** Requête sans identité : ne voit que ce qui est public au sens des policies. */
export async function anonyme(texte, valeurs) {
  return avecUtilisateur(null, (client) => client.query(texte, valeurs));
}
