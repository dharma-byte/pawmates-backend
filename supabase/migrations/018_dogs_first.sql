-- Pawmates is dog-first: dogs are the pets that meet outside. Cats can still
-- join; new birds, rabbits and other pets cannot. NOT VALID leaves any
-- existing rows alone while every insert and update is checked.

alter table public.pets
  add constraint pets_species_dog_or_cat check (species in ('dog', 'cat')) not valid;
