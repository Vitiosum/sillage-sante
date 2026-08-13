-- ---------------------------------------------------------------------------
-- 15. Geolocalisation des cabinets de demonstration
-- ---------------------------------------------------------------------------
-- 20260813130000 posait deja ces positions, mais il s'est execute avant que
-- seed.sql ne soit joue : `supabase db push` n'inclut le seed que sur
-- --include-seed, et sa sortie le dit franchement ("seeds":[]). Les deux
-- update ne trouvaient aucune ligne.
--
-- Cette migration les rejoue apres le seed. Elle est idempotente : elle
-- n'ecrit que si la position est absente ou differente.
-- ---------------------------------------------------------------------------

do $$
begin
  update medical.cabinets
     set position = extensions.st_point(-2.2137, 47.2735)::extensions.geography
   where finess = '440000123'                        -- Saint-Nazaire
     and position is distinct from extensions.st_point(-2.2137, 47.2735)::extensions.geography;

  update medical.cabinets
     set position = extensions.st_point(-3.3660, 47.7480)::extensions.geography
   where finess = '560000456'                        -- Lorient
     and position is distinct from extensions.st_point(-3.3660, 47.7480)::extensions.geography;

  if (select count(*) from medical.cabinets where position is not null) = 0 then
    raise warning 'Aucun cabinet geolocalise : seed.sql n''a pas ete joue. Relancer avec `supabase db push --include-seed`.';
  end if;
exception when undefined_function then
  raise warning 'PostGIS indisponible : positions non posees (%)', sqlerrm;
end
$$;
