-- Jeu de donnees de demonstration (aucune donnee reelle).
-- Les utilisateurs sont crees via GoTrue, pas ici : le trigger
-- medical.gerer_nouvel_utilisateur() alimente profils et patients.

insert into medical.cabinets (id, raison_sociale, finess, adresse, code_postal, ville) values
  ('11111111-1111-1111-1111-111111111111', 'Maison de sante du Bord de Loire', '440000123', '12 quai Demange', '44600', 'Saint-Nazaire'),
  ('22222222-2222-2222-2222-222222222222', 'Centre medical Bretagne Sud',      '560000456', '8 rue des Douves',  '56100', 'Lorient')
on conflict do nothing;

-- Praticiens : profil_id a remplacer par les UUID reels apres inscription
-- via `supabase auth admin create-user` ou le dashboard.
