-- ---------------------------------------------------------------------------
-- 05. Row Level Security
-- ---------------------------------------------------------------------------
-- Principe : deny by default. Trois axes d'acces
--   - le patient accede a son propre dossier (auth.uid() -> profils -> patients)
--   - le praticien accede aux dossiers pour lesquels il a une prise en charge
--   - le secretariat accede a l'agenda mais jamais au contenu medical
-- ---------------------------------------------------------------------------

alter table medical.profils          enable row level security;
alter table medical.cabinets         enable row level security;
alter table medical.praticiens       enable row level security;
alter table medical.patients         enable row level security;
alter table medical.prises_en_charge enable row level security;
alter table medical.rendez_vous      enable row level security;
alter table medical.consultations    enable row level security;
alter table medical.ordonnances      enable row level security;
alter table medical.documents        enable row level security;
alter table medical.conversations    enable row level security;
alter table medical.messages         enable row level security;
alter table medical.notifications    enable row level security;
alter table medical.consentements    enable row level security;

alter table medical.consultations force row level security;
alter table medical.documents     force row level security;

-- --- Profils ---------------------------------------------------------------
create policy "profil lisible par son proprietaire"
  on medical.profils for select to authenticated
  using (id = auth.uid());

create policy "profil modifiable par son proprietaire"
  on medical.profils for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role_metier = medical.role_courant());

create policy "profils des praticiens visibles par leurs patients"
  on medical.profils for select to authenticated
  using (
    exists (
      select 1
      from medical.praticiens pr
      join medical.prises_en_charge pec on pec.praticien_id = pr.id
      where pr.profil_id = medical.profils.id
        and pec.patient_id = medical.patient_courant()
    )
  );

-- --- Annuaire public -------------------------------------------------------
create policy "cabinets consultables par tous"
  on medical.cabinets for select to anon, authenticated using (true);

create policy "praticiens actifs consultables par tous"
  on medical.praticiens for select to anon, authenticated using (actif);

create policy "praticien modifie sa propre fiche"
  on medical.praticiens for update to authenticated
  using (profil_id = auth.uid()) with check (profil_id = auth.uid());

-- --- Patients --------------------------------------------------------------
create policy "patient lit son dossier"
  on medical.patients for select to authenticated
  using (profil_id = auth.uid());

create policy "praticien lit les dossiers pris en charge"
  on medical.patients for select to authenticated
  using (medical.a_une_prise_en_charge(id));

create policy "secretariat lit l'identite des patients du cabinet"
  on medical.patients for select to authenticated
  using (
    medical.role_courant() = 'secretariat'
    and exists (
      select 1
      from medical.prises_en_charge pec
      join medical.praticiens pr on pr.id = pec.praticien_id
      join medical.profils sec on sec.id = auth.uid()
      join medical.praticiens ref on ref.cabinet_id = pr.cabinet_id
      where pec.patient_id = medical.patients.id
        and ref.profil_id = sec.id
    )
  );

create policy "patient met a jour ses coordonnees"
  on medical.patients for update to authenticated
  using (profil_id = auth.uid())
  with check (profil_id = auth.uid());

-- --- Prises en charge ------------------------------------------------------
create policy "prise en charge visible par les deux parties"
  on medical.prises_en_charge for select to authenticated
  using (
    patient_id = medical.patient_courant()
    or praticien_id = medical.praticien_courant()
  );

create policy "praticien cloture sa prise en charge"
  on medical.prises_en_charge for update to authenticated
  using (praticien_id = medical.praticien_courant())
  with check (praticien_id = medical.praticien_courant());

-- --- Agenda ----------------------------------------------------------------
create policy "rdv visibles par le patient"
  on medical.rendez_vous for select to authenticated
  using (patient_id = medical.patient_courant());

create policy "rdv visibles par le praticien"
  on medical.rendez_vous for select to authenticated
  using (praticien_id = medical.praticien_courant());

create policy "patient demande un rdv"
  on medical.rendez_vous for insert to authenticated
  with check (patient_id = medical.patient_courant() and statut = 'demande');

create policy "patient annule son rdv"
  on medical.rendez_vous for update to authenticated
  using (patient_id = medical.patient_courant() and lower(creneau) > now())
  with check (statut = 'annule');

create policy "praticien gere ses rdv"
  on medical.rendez_vous for all to authenticated
  using (praticien_id = medical.praticien_courant())
  with check (praticien_id = medical.praticien_courant());

-- --- Consultations : le coeur du secret medical ----------------------------
create policy "patient lit ses comptes rendus clotures"
  on medical.consultations for select to authenticated
  using (patient_id = medical.patient_courant() and cloturee_a is not null);

create policy "praticien lit les consultations de ses patients"
  on medical.consultations for select to authenticated
  using (medical.a_une_prise_en_charge(patient_id) and medical.mfa_verifiee());

create policy "praticien redige ses consultations"
  on medical.consultations for insert to authenticated
  with check (praticien_id = medical.praticien_courant() and medical.mfa_verifiee());

create policy "praticien modifie ses consultations non cloturees"
  on medical.consultations for update to authenticated
  using (praticien_id = medical.praticien_courant() and cloturee_a is null)
  with check (praticien_id = medical.praticien_courant());

-- --- Ordonnances -----------------------------------------------------------
create policy "ordonnances lisibles par le patient concerne"
  on medical.ordonnances for select to authenticated
  using (
    exists (
      select 1 from medical.consultations c
      where c.id = consultation_id and c.patient_id = medical.patient_courant()
    )
  );

create policy "ordonnances gerees par le prescripteur"
  on medical.ordonnances for all to authenticated
  using (
    exists (
      select 1 from medical.consultations c
      where c.id = consultation_id and c.praticien_id = medical.praticien_courant()
    )
  )
  with check (
    exists (
      select 1 from medical.consultations c
      where c.id = consultation_id and c.praticien_id = medical.praticien_courant()
    )
  );

-- --- Documents -------------------------------------------------------------
create policy "documents sains lisibles par le patient"
  on medical.documents for select to authenticated
  using (patient_id = medical.patient_courant() and statut_scan = 'sain');

create policy "documents sains lisibles par le praticien"
  on medical.documents for select to authenticated
  using (medical.a_une_prise_en_charge(patient_id) and statut_scan = 'sain');

create policy "depot de document par une partie autorisee"
  on medical.documents for insert to authenticated
  with check (
    deposant_id = auth.uid()
    and (patient_id = medical.patient_courant() or medical.a_une_prise_en_charge(patient_id))
  );

-- --- Messagerie ------------------------------------------------------------
create policy "conversations visibles par les participants"
  on medical.conversations for select to authenticated
  using (
    patient_id = medical.patient_courant()
    or praticien_id = medical.praticien_courant()
  );

create policy "ouverture d'une conversation"
  on medical.conversations for insert to authenticated
  with check (
    patient_id = medical.patient_courant()
    or praticien_id = medical.praticien_courant()
  );

create policy "messages visibles par les participants"
  on medical.messages for select to authenticated
  using (
    exists (
      select 1 from medical.conversations c
      where c.id = conversation_id
        and (c.patient_id = medical.patient_courant() or c.praticien_id = medical.praticien_courant())
    )
  );

create policy "envoi de message dans une conversation ouverte"
  on medical.messages for insert to authenticated
  with check (
    auteur_id = auth.uid()
    and exists (
      select 1 from medical.conversations c
      where c.id = conversation_id
        and not c.cloturee
        and (c.patient_id = medical.patient_courant() or c.praticien_id = medical.praticien_courant())
    )
  );

create policy "accuse de lecture"
  on medical.messages for update to authenticated
  using (auteur_id <> auth.uid())
  with check (lu_a is not null);

-- --- Notifications et consentements ----------------------------------------
create policy "notifications personnelles"
  on medical.notifications for select to authenticated
  using (destinataire_id = auth.uid());

create policy "consentements du patient"
  on medical.consentements for select to authenticated
  using (patient_id = medical.patient_courant() or medical.a_une_prise_en_charge(patient_id));

create policy "patient exprime son consentement"
  on medical.consentements for insert to authenticated
  with check (patient_id = medical.patient_courant());

-- --- Acces machine ---------------------------------------------------------
-- Les batchs de nuit utilisent service_role (BYPASSRLS), les Edge Functions
-- appellent PostgREST avec la cle service_role.
grant select, insert, update on all tables in schema medical to service_role;
grant select on all tables in schema audit to service_role;
