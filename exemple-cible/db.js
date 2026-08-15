// ---------------------------------------------------------------------------
// Accès base — garder la RLS sans les rôles Supabase.
//
// Chez Supabase, PostgREST se connecte en `authenticator` et endosse `anon` ou
// `authenticated` selon le JWT ; les policies lisent auth.uid().
//
// Un add-on PostgreSQL managé ne permet pas de créer ces rôles par défaut
// (le support étudie ce type de demande — réponse écrite avant de planifier).
// Ce n'est de toute façon pas bloquant : la RLS ne dépend pas d'eux, elle
// dépend d'un contexte lisible en SQL, posé par transaction.
//
// PRÉREQUIS NON NÉGOCIABLE : l'application se connecte avec le rôle de
// l'add-on, qui est PROPRIÉTAIRE des tables (c'est lui qui joue les
// migrations). Or un propriétaire CONTOURNE la RLS, sauf si la table porte
//     alter table ma_table force row level security;
// Sans ce FORCE sur chaque table protégée, toutes les policies sont
// silencieusement ignorées et chaque requête voit tout. À vérifier :
//     select relname from pg_class
//      where relrowsecurity and not relforcerowsecurity;
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
  // Ne jamais poser la chaîne vide : contrairement à NULL, '' EST une valeur
  // pour current_setting, et ''::uuid lève 22P02 dans chaque policy. Un
  // identifiant absent ou mal formé => on ne pose rien, et
  // current_setting(..., true) renverra NULL : les policies ne voient rien.
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const contexte = UUID.test(utilisateurId ?? '') ? utilisateurId : null;

  const client = await pool.connect();
  try {
    await client.query('begin');
    if (contexte) {
      // set_config(..., true) = équivalent de `set local`, mais paramétrable :
      // jamais d'interpolation de chaîne dans du SQL.
      await client.query("select set_config('app.utilisateur_id', $1, true)", [contexte]);
    }
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
