// ---------------------------------------------------------------------------
// Le backend qui remplace PostgREST, GoTrue et Realtime.
//
// Chez Supabase, le navigateur appelait PostgREST directement et la RLS faisait
// l'autorisation. Ici, chaque route est explicite — mais la RLS reste en base
// (voir db.js). On garde la défense en profondeur, on perd la génération
// automatique des routes.
//
// C'est l'échange central de cette migration : plus de code, moins de magie,
// et aucune dépendance à un composant sans équivalent ailleurs.
// ---------------------------------------------------------------------------
import express from 'express';
import { avecUtilisateur, pool } from './db.js';
import { urlSignee } from './stockage.js';

const app = express();
app.use(express.json());

// --- Identité ---------------------------------------------------------------
// Le squelette suppose l'utilisateur déjà authentifié. À brancher sur une
// vérification de JWT, ou sur un add-on Keycloak — c'est ce qui remplace GoTrue.
app.use((req, _res, suite) => {
  req.utilisateurId = req.get('x-utilisateur-id') || null;
  suite();
});

// --- Santé ------------------------------------------------------------------
// Une vraie sonde interroge la base : un processus vivant dont la base est
// injoignable n'est pas « en bonne santé ».
app.get('/sante', async (_req, res) => {
  try {
    await pool.query('select 1');
    res.json({ etat: 'ok' });
  } catch {
    res.status(503).json({ etat: 'base injoignable' });
  }
});

// --- Lecture ----------------------------------------------------------------
// Remplace :  GET /rest/v1/patients
// La requête est explicite, mais c'est toujours la POLICY qui décide de ce qui
// sort. Retirer avecUtilisateur() ne donnerait pas plus de droits : sans
// contexte, les policies ne trouvent rien.
app.get('/patients', async (req, res, suite) => {
  try {
    const { rows } = await avecUtilisateur(req.utilisateurId, (client) =>
      client.query('select id, nom_naissance, prenom from medical.patients'),
    );
    res.json(rows);
  } catch (e) {
    suite(e);
  }
});

// --- Écriture ---------------------------------------------------------------
// Remplace :  POST /rest/v1/rendez_vous
// Note : `creneau` est un tstzrange. Une plage ne se compare pas à un
// timestamp — l'erreur classique de reprise, et elle ne se voit qu'à
// l'exécution.
app.post('/rendez-vous', async (req, res, suite) => {
  const { praticienId, patientId, debut, fin } = req.body;
  try {
    const { rows } = await avecUtilisateur(req.utilisateurId, (client) =>
      client.query(
        `insert into medical.rendez_vous (praticien_id, patient_id, creneau)
         values ($1, $2, tstzrange($3::timestamptz, $4::timestamptz))
         returning id`,
        [praticienId, patientId, debut, fin],
      ),
    );
    res.status(201).json(rows[0]);
  } catch (e) {
    suite(e);
  }
});

// --- Document ---------------------------------------------------------------
// Remplace :  supabase.storage.from(...).createSignedUrl(...)
// Différence de fond : Supabase vérifiait aussi les policies du bucket. Ici il
// faut vérifier les droits AVANT de signer — c'est fait par la requête, dont
// la policy filtre.
app.get('/documents/:id/url', async (req, res, suite) => {
  try {
    const { rows } = await avecUtilisateur(req.utilisateurId, (client) =>
      client.query('select chemin from medical.documents where id = $1', [req.params.id]),
    );
    if (!rows.length) return res.status(404).json({ erreur: 'introuvable' });
    res.json({ url: await urlSignee('documents-medicaux', rows[0].chemin, 60) });
  } catch (e) {
    suite(e);
  }
});

// --- Tâches planifiées ------------------------------------------------------
// Remplace :  pg_cron + pg_net appelant une Edge Function.
// Appelé par clevercloud/tache.sh, protégé par un jeton : cette route ne doit
// pas être publique.
app.post('/taches/:nom', async (req, res, suite) => {
  if (req.get('authorization') !== `Bearer ${process.env.API_SERVICE_TOKEN}`) {
    return res.status(401).json({ erreur: 'non autorisé' });
  }
  try {
    // La logique métier vit ici, testable hors production — contrairement à un
    // trigger en base.
    res.json({ tache: req.params.nom, traites: 0 });
  } catch (e) {
    suite(e);
  }
});

// eslint-disable-next-line no-unused-vars
app.use((erreur, _req, res, _suite) => {
  console.error(erreur);
  res.status(500).json({ erreur: 'erreur interne' });
});

// La plateforme impose le port par la variable PORT.
const port = process.env.PORT || 8080;
app.listen(port, () => console.log(`à l'écoute sur ${port}`));
