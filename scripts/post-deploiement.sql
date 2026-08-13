-- ---------------------------------------------------------------------------
-- Seule etape de post-deploiement qui ne peut pas passer par une migration.
--
-- NE MODIFIE PAS CE FICHIER. Il est suivi par git et le depot est public :
-- y coller la cle service_role la publie au commit suivant.
--
-- Lancer a la place :
--     ./scripts/post-deploiement.sh <project-ref>
--
-- Le script substitue la valeur depuis .env.local et la met dans le
-- presse-papier. Coller dans un onglet SQL Editor VIDE, puis Run.
-- ---------------------------------------------------------------------------
-- Tout le reste (jobs cron, URL antivirus, Database Webhook, positions
-- PostGIS) est passe dans la migration 20260813130000_post_deploiement.sql :
-- ces instructions lisent le Vault a l'execution et ne portent aucun secret.
--
-- Tant que cette ligne n'est pas jouee, les 5 jobs cron sont inertes : le
-- header Authorization vaut NULL et les Edge Functions repondent 401.
--
-- Controle attendu apres execution :
--   select name, length(decrypted_secret) from vault.decrypted_secrets
--    where name = 'service_role_key';
-- La longueur doit correspondre a la cle du dashboard, pas a la valeur
-- par defaut de 26 caracteres posee par la migration 090800.
-- ---------------------------------------------------------------------------

select vault.update_secret(
  (select id from vault.secrets where name = 'service_role_key'),
  '<SERVICE_ROLE_KEY>'
);

select name, length(decrypted_secret) as longueur
  from vault.decrypted_secrets
 where name = 'service_role_key';
