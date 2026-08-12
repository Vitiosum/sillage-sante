-- ---------------------------------------------------------------------------
-- 03. Modele de donnees
-- ---------------------------------------------------------------------------

create type medical.role_metier as enum ('patient', 'praticien', 'secretariat', 'admin');
create type medical.statut_rdv  as enum ('demande', 'confirme', 'honore', 'annule', 'absent');
create type medical.statut_scan as enum ('en_attente', 'sain', 'infecte', 'erreur');
create type medical.canal_notif as enum ('email', 'sms', 'push');

-- --- Profils ---------------------------------------------------------------
create table medical.profils (
  id              uuid primary key references auth.users (id) on delete cascade,
  role_metier     medical.role_metier not null default 'patient',
  nom             text not null,
  prenom          text not null,
  telephone       text,
  avatar_url      text,
  cgu_acceptees_a timestamptz,
  cree_a          timestamptz not null default now(),
  maj_a           timestamptz not null default now()
);

create table medical.cabinets (
  id            uuid primary key default extensions.uuid_generate_v4(),
  raison_sociale text not null,
  finess        text unique,
  adresse       text not null,
  code_postal   text not null,
  ville         text not null,
  cree_a        timestamptz not null default now()
);

create table medical.praticiens (
  id          uuid primary key default extensions.uuid_generate_v4(),
  profil_id   uuid not null unique references medical.profils (id) on delete cascade,
  cabinet_id  uuid references medical.cabinets (id) on delete set null,
  rpps        char(11) not null unique,
  specialite  text not null,
  secteur     smallint not null default 1 check (secteur in (1, 2, 3)),
  actif       boolean not null default true
);

create table medical.patients (
  id                 uuid primary key default extensions.uuid_generate_v4(),
  profil_id          uuid unique references medical.profils (id) on delete set null,
  nom_naissance      text not null,
  prenom             text not null,
  date_naissance     date not null,
  -- NIR chiffre au repos par pgsodium (Transparent Column Encryption)
  nir_chiffre        text,
  nir_key_id         uuid,
  medecin_traitant_id uuid references medical.praticiens (id) on delete set null,
  cree_a             timestamptz not null default now(),
  maj_a              timestamptz not null default now()
);

security label for pgsodium
  on column medical.patients.nir_chiffre
  is 'ENCRYPT WITH KEY COLUMN nir_key_id SECURITY INVOKER';

-- --- Prise en charge : la table qui pilote toutes les policies RLS ----------
create table medical.prises_en_charge (
  id           uuid primary key default extensions.uuid_generate_v4(),
  patient_id   uuid not null references medical.patients (id) on delete cascade,
  praticien_id uuid not null references medical.praticiens (id) on delete cascade,
  debut        date not null default current_date,
  fin          date,
  motif        text,
  unique (patient_id, praticien_id, debut)
);

create index on medical.prises_en_charge (praticien_id) where fin is null;
create index on medical.prises_en_charge (patient_id);

-- --- Agenda ----------------------------------------------------------------
create table medical.rendez_vous (
  id               uuid primary key default extensions.uuid_generate_v4(),
  praticien_id     uuid not null references medical.praticiens (id) on delete cascade,
  patient_id       uuid not null references medical.patients (id) on delete cascade,
  creneau          tstzrange not null,
  statut           medical.statut_rdv not null default 'demande',
  motif            text,
  teleconsultation boolean not null default false,
  rappel_envoye_a  timestamptz,
  cree_a           timestamptz not null default now(),
  maj_a            timestamptz not null default now(),
  -- pas de double reservation sur un meme praticien
  exclude using gist (
    praticien_id with =,
    creneau with &&
  ) where (statut <> 'annule')
);

create index on medical.rendez_vous using gist (creneau);
create index on medical.rendez_vous (patient_id, statut);

-- --- Consultations et comptes rendus ---------------------------------------
create table medical.consultations (
  id             uuid primary key default extensions.uuid_generate_v4(),
  rendez_vous_id uuid not null unique references medical.rendez_vous (id) on delete cascade,
  praticien_id   uuid not null references medical.praticiens (id),
  patient_id     uuid not null references medical.patients (id),
  compte_rendu   text,
  diagnostic_cim10 text[],
  duree_minutes  smallint,
  -- embedding du compte rendu, alimente par la fonction recherche-semantique
  embedding      extensions.vector(1536),
  cloturee_a     timestamptz,
  cree_a         timestamptz not null default now(),
  maj_a          timestamptz not null default now()
);

create index on medical.consultations
  using ivfflat (embedding extensions.vector_cosine_ops) with (lists = 100);
create index on medical.consultations
  using gin (to_tsvector('french', coalesce(compte_rendu, '')));

create table medical.ordonnances (
  id              uuid primary key default extensions.uuid_generate_v4(),
  consultation_id uuid not null references medical.consultations (id) on delete cascade,
  lignes          jsonb not null default '[]'::jsonb,
  pdf_chemin      text,
  empreinte_sha256 text,
  signee_a        timestamptz,
  cree_a          timestamptz not null default now()
);

-- --- Documents (adosses au Storage) ----------------------------------------
create table medical.documents (
  id           uuid primary key default extensions.uuid_generate_v4(),
  patient_id   uuid not null references medical.patients (id) on delete cascade,
  deposant_id  uuid not null references medical.profils (id),
  bucket       text not null default 'documents-medicaux',
  chemin       text not null unique,
  nom_affiche  text not null,
  mime         text not null,
  taille_octets bigint not null,
  chiffre      boolean not null default true,
  statut_scan  medical.statut_scan not null default 'en_attente',
  cree_a       timestamptz not null default now()
);

create index on medical.documents (patient_id, cree_a desc);

-- --- Messagerie securisee (temps reel) -------------------------------------
create table medical.conversations (
  id           uuid primary key default extensions.uuid_generate_v4(),
  patient_id   uuid not null references medical.patients (id) on delete cascade,
  praticien_id uuid not null references medical.praticiens (id) on delete cascade,
  sujet        text,
  cloturee     boolean not null default false,
  cree_a       timestamptz not null default now(),
  unique (patient_id, praticien_id, sujet)
);

create table medical.messages (
  id              uuid primary key default extensions.uuid_generate_v4(),
  conversation_id uuid not null references medical.conversations (id) on delete cascade,
  auteur_id       uuid not null references medical.profils (id),
  corps           text not null check (length(corps) between 1 and 8000),
  lu_a            timestamptz,
  cree_a          timestamptz not null default now()
);

create index on medical.messages (conversation_id, cree_a desc);

-- --- Notifications et consentements ----------------------------------------
create table medical.notifications (
  id           uuid primary key default extensions.uuid_generate_v4(),
  destinataire_id uuid not null references medical.profils (id) on delete cascade,
  canal        medical.canal_notif not null default 'email',
  sujet        text not null,
  corps        text not null,
  envoyee_a    timestamptz,
  erreur       text,
  cree_a       timestamptz not null default now()
);

create table medical.consentements (
  id          uuid primary key default extensions.uuid_generate_v4(),
  patient_id  uuid not null references medical.patients (id) on delete cascade,
  finalite    text not null,
  accorde     boolean not null,
  preuve      jsonb,
  horodatage  timestamptz not null default now()
);

-- --- Journal d'acces (schema audit, non expose) ----------------------------
create table audit.journal_acces (
  id          bigserial primary key,
  acteur_id   uuid,
  role_effectif text,
  action      text not null,
  table_cible text not null,
  ligne_id    uuid,
  avant       jsonb,
  apres       jsonb,
  ip          inet,
  horodatage  timestamptz not null default now()
);

create index on audit.journal_acces (horodatage desc);
create index on audit.journal_acces (acteur_id, horodatage desc);
