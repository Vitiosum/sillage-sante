-- ---------------------------------------------------------------------------
-- 10. Geolocalisation des cabinets (PostGIS)
-- ---------------------------------------------------------------------------
-- Le patient cherche un praticien autour de lui. PostGIS est disponible sur
-- Supabase Cloud mais reste une extension lourde : sa presence est a verifier
-- sur toute plateforme cible.
-- ---------------------------------------------------------------------------

do $$
begin
  create extension if not exists postgis with schema extensions;
exception when others then
  raise warning 'PostGIS absent : la recherche par proximite sera indisponible.';
end
$$;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'postgis') then
    return;
  end if;

  alter table medical.cabinets
    add column if not exists position extensions.geography(point, 4326);

  execute 'create index if not exists cabinets_position_idx
             on medical.cabinets using gist (position)';
end
$$;

-- Recherche des praticiens dans un rayon donne, tries par distance.
-- Exposee a anon : c'est l'annuaire public.
create or replace function public.praticiens_a_proximite(
  p_latitude   double precision,
  p_longitude  double precision,
  p_rayon_km   double precision default 15,
  p_specialite text default null
)
returns table (
  praticien_id uuid,
  specialite   text,
  cabinet      text,
  ville        text,
  distance_km  double precision
)
language sql stable
set search_path = medical, public, extensions
as $$
  select pr.id,
         pr.specialite,
         c.raison_sociale,
         c.ville,
         round((st_distance(
           c.position,
           st_point(p_longitude, p_latitude)::geography
         ) / 1000)::numeric, 2)::double precision
  from medical.praticiens pr
  join medical.cabinets c on c.id = pr.cabinet_id
  where pr.actif
    and c.position is not null
    and st_dwithin(c.position, st_point(p_longitude, p_latitude)::geography, p_rayon_km * 1000)
    and (p_specialite is null or pr.specialite ilike '%' || p_specialite || '%')
  order by c.position <-> st_point(p_longitude, p_latitude)::geography
  limit 50;
$$;

grant execute on function public.praticiens_a_proximite(double precision, double precision, double precision, text)
  to anon, authenticated;

-- Zone d'intervention pour les visites a domicile
create table if not exists medical.zones_intervention (
  id           uuid primary key default extensions.uuid_generate_v4(),
  praticien_id uuid not null references medical.praticiens (id) on delete cascade,
  libelle      text not null,
  perimetre    extensions.geography(polygon, 4326),
  unique (praticien_id, libelle)
);

alter table medical.zones_intervention enable row level security;

create policy "zones visibles publiquement"
  on medical.zones_intervention for select to anon, authenticated using (true);

create policy "praticien gere ses zones"
  on medical.zones_intervention for all to authenticated
  using (praticien_id = medical.praticien_courant())
  with check (praticien_id = medical.praticien_courant());
