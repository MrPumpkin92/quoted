-- Verified quotes: the server marks a quote or share whose wording and
-- attribution are exactly a starter-pack quote, which was checked word for
-- word against a public-domain edition (docs/starter-pack-sources.md).
-- Contract: docs/system-design.md section 3. Tests:
-- supabase/tests/database/14_verified_quotes.test.sql.
--
-- 1. starter_quotes gains source_location (where in the work, for people) and
--    source_url (the full text it was checked against).
-- 2. quotes and shares gain verified_starter_id, the starter quote whose body,
--    author and source the row matches exactly, or null. A trigger computes it
--    on every insert and on every update that touches the text or the column
--    itself, so a client can never set it: whatever it sends is replaced.
--    Editing the wording, author or source of a verified quote clears it;
--    formatting (body_format) does not count. A shared verified quote stays
--    verified for the recipient, because the share carries the same text.
-- 3. Existing rows are backfilled, without moving quotes.updated_at.

alter table public.starter_quotes
  add column source_location text,
  add column source_url text;

update public.starter_quotes s
set source_location = v.source_location, source_url = v.source_url
from (values
  (1, $q$Essays: First Series (1841), 3rd paragraph$q$, $q$https://www.gutenberg.org/ebooks/2944$q$),
  (2, $q$Poems, Second Series (1891), stanza 1$q$, $q$https://www.gutenberg.org/ebooks/2679$q$),
  (3, $q$1831 edition, Chapter 20$q$, $q$https://www.gutenberg.org/ebooks/42324$q$),
  (4, $q$Letter I, “On Saving Time”, §2$q$, $q$https://en.wikisource.org/wiki/Moral_letters_to_Lucilius/Letter_1$q$),
  (5, $q$Chapter 31, Elizabeth to Darcy$q$, $q$https://www.gutenberg.org/ebooks/1342$q$),
  (6, $q$Leaves of Grass (1891–92), section 51$q$, $q$https://www.gutenberg.org/ebooks/1322$q$),
  (7, $q$Act I, Scene 7, Lady Macbeth$q$, $q$https://www.gutenberg.org/ebooks/1533$q$),
  (8, $q$Chapter 2, “Where I Lived, and What I Lived For”$q$, $q$https://www.gutenberg.org/ebooks/205$q$),
  (9, $q$Act I, Scene 3, Polonius to Laertes$q$, $q$https://www.gutenberg.org/ebooks/1524$q$),
  (10, $q$Stray Birds (1916), no. 6$q$, $q$https://www.gutenberg.org/ebooks/6524$q$),
  (11, $q$Chapter 21, Anne to Marilla$q$, $q$https://www.gutenberg.org/ebooks/45$q$),
  (12, $q$Book VIII, §47$q$, $q$https://www.gutenberg.org/ebooks/15877$q$),
  (13, $q$Chapter 23, Jane to Rochester$q$, $q$https://www.gutenberg.org/ebooks/1260$q$),
  (14, $q$Chapter 64, §2$q$, $q$https://www.gutenberg.org/ebooks/216$q$),
  (15, $q$Chapter 12 epigraph, “Pudd’nhead Wilson’s Calendar”$q$, $q$https://www.gutenberg.org/ebooks/102$q$),
  (16, $q$Goblin Market and Other Poems (1862), stanza 1$q$, $q$https://www.gutenberg.org/ebooks/16950$q$),
  (17, $q$Chapter X$q$, $q$https://www.gutenberg.org/ebooks/23$q$),
  (18, $q$“On Work”$q$, $q$https://www.gutenberg.org/ebooks/58585$q$),
  (19, $q$Chapter V, the White Queen$q$, $q$https://www.gutenberg.org/ebooks/12$q$),
  (20, $q$Chapter 72, Dorothea$q$, $q$https://www.gutenberg.org/ebooks/145$q$),
  (21, $q$Section V$q$, $q$https://www.gutenberg.org/ebooks/10661$q$),
  (22, $q$Opening pages (1925), Clarissa’s thoughts$q$, $q$https://www.gutenberg.org/ebooks/71865$q$),
  (23, $q$Book IX, Chapter XXVIII$q$, $q$https://www.gutenberg.org/ebooks/3330$q$),
  (24, $q$Virginibus Puerisque (1881), last sentence$q$, $q$https://www.gutenberg.org/ebooks/386$q$),
  (25, $q$Sonnet XLIII, lines 1–4$q$, $q$https://www.gutenberg.org/ebooks/2002$q$),
  (26, $q$Poems (1842), last lines$q$, $q$https://www.gutenberg.org/ebooks/8601$q$),
  (27, $q$Book I, Chapter II$q$, $q$https://www.gutenberg.org/ebooks/242$q$),
  (28, $q$The Complete Poems (1913), stanza 2$q$, $q$https://www.gutenberg.org/ebooks/18338$q$),
  (29, $q$Section 38a, Socrates after the verdict$q$, $q$https://www.gutenberg.org/ebooks/1656$q$),
  (30, $q$Chapter 44, “My Lord and Lady”, Amy$q$, $q$https://www.gutenberg.org/ebooks/514$q$),
  (31, $q$Chapter VI, journal entry for July 27$q$, $q$https://www.gutenberg.org/ebooks/32540$q$),
  (32, $q$Chapter XVII (Anger), verse 223$q$, $q$https://www.gutenberg.org/ebooks/2017$q$),
  (33, $q$Act III, Lord Darlington$q$, $q$https://www.gutenberg.org/ebooks/790$q$),
  (34, $q$Love Songs (1917), stanza 1$q$, $q$https://www.gutenberg.org/ebooks/442$q$),
  (35, $q$Essays, Book I, Chapter XXXVIII$q$, $q$https://www.gutenberg.org/ebooks/3600$q$),
  (36, $q$4 March 1865, final paragraph$q$, $q$https://en.wikisource.org/wiki/Abraham_Lincoln%27s_Second_Inaugural_Address$q$),
  (37, $q$Book I, lines 1–3$q$, $q$https://www.gutenberg.org/ebooks/24280$q$),
  (38, $q$Chapter 4$q$, $q$https://www.gutenberg.org/ebooks/3420$q$),
  (39, $q$Song XLIII (1915), lines 1–2$q$, $q$https://www.gutenberg.org/ebooks/6519$q$),
  (40, $q$Poems (1898), final stanza$q$, $q$https://en.wikisource.org/wiki/Poems_(Henley)/Out_of_the_night_that_covers_me$q$),
  (41, $q$Chapter XXVII, “In the Garden”$q$, $q$https://www.gutenberg.org/ebooks/113$q$),
  (42, $q$Book VI, Chapter III, Father Zossima$q$, $q$https://www.gutenberg.org/ebooks/28054$q$),
  (43, $q$Complete Poems (1908), stanza 1$q$, $q$https://en.wikisource.org/wiki/The_Complete_Poems_of_Emily_Bront%C3%AB/No_Coward_Soul_Is_Mine$q$),
  (44, $q$Title essay, last sentence$q$, $q$https://www.gutenberg.org/ebooks/8092$q$),
  (45, $q$Chapter I, “The Cup of Humanity”$q$, $q$https://www.gutenberg.org/ebooks/769$q$),
  (46, $q$Voices of the Night (1839), final stanza$q$, $q$https://en.wikisource.org/wiki/Voices_of_the_Night/A_Psalm_of_Life$q$),
  (47, $q$Akron, Ohio, 29 May 1851, as reported in the Anti-Slavery Bugle$q$, $q$https://en.wikisource.org/wiki/Sojourner_Truth%27s_Women%27s_Rights_Convention_Speech_(1851)$q$),
  (48, $q$Pickering Manuscript (c. 1803), lines 1–4$q$, $q$https://en.wikisource.org/wiki/The_Pickering_Manuscript/Auguries_of_Innocence$q$),
  (49, $q$Book Ten, Chapter XVI, Kutúzov to Prince Andrew$q$, $q$https://www.gutenberg.org/ebooks/2600$q$),
  (50, $q$Renascence and Other Poems (1917), closing lines$q$, $q$https://www.gutenberg.org/ebooks/109$q$),
  (51, $q$Book IV, Part II, Chapter 12$q$, $q$https://en.wikisource.org/wiki/The_Chinese_Classics/Volume_2/The_Works_of_Mencius/chapter08$q$),
  (52, $q$Book III, Chapter 9, John Rokesmith to Bella$q$, $q$https://www.gutenberg.org/ebooks/883$q$),
  (53, $q$Prometheus Unbound, with Other Poems (1820), last line$q$, $q$https://en.wikisource.org/wiki/Prometheus_Unbound;_a_lyrical_drama_in_four_acts_with_other_poems/Ode_to_the_West_Wind$q$),
  (54, $q$Chapter II, “Boyhood Days”$q$, $q$https://www.gutenberg.org/ebooks/2376$q$),
  (55, $q$Book V, Chapter I, Serlo$q$, $q$https://www.gutenberg.org/ebooks/36483$q$),
  (56, $q$American Indian Stories (1921)$q$, $q$https://www.gutenberg.org/ebooks/10376$q$),
  (57, $q$Men and Women (1855), lines 97–98$q$, $q$https://www.gutenberg.org/ebooks/17393$q$),
  (58, $q$Poems in Two Volumes (1807), lines 1–6$q$, $q$https://www.gutenberg.org/ebooks/8824$q$),
  (59, $q$Chapter IV, “Barbarism and the Moral Code”$q$, $q$https://www.gutenberg.org/ebooks/340$q$),
  (60, $q$Meditation XVII (spelling modernized)$q$, $q$https://en.wikisource.org/wiki/Devotions/Meditation_17$q$)
) as v (id, source_location, source_url)
where s.id = v.id;

alter table public.starter_quotes
  alter column source_location set not null,
  alter column source_url set not null,
  add constraint starter_quotes_source_location_length check (char_length(source_location) between 1 and 200),
  add constraint starter_quotes_source_url_https check (source_url ~ '^https://[^[:space:]]+$' and char_length(source_url) <= 500);

comment on column public.starter_quotes.source_location is 'Where the quote is in the work, for people ("Chapter 20"). Shown in the app''s Verified quote sheet.';
comment on column public.starter_quotes.source_url is 'The public-domain full text the quote was checked against (Project Gutenberg or Wikisource).';

alter table public.quotes
  add column verified_starter_id smallint,
  add constraint quotes_verified_starter_id_fkey foreign key (verified_starter_id)
    references public.starter_quotes (id) on delete set null;
alter table public.shares
  add column verified_starter_id smallint,
  add constraint shares_verified_starter_id_fkey foreign key (verified_starter_id)
    references public.starter_quotes (id) on delete set null;

-- Foreign key columns lead an index (00_schema); few rows are verified.
create index quotes_verified_starter_id_idx on public.quotes (verified_starter_id)
  where verified_starter_id is not null;
create index shares_verified_starter_id_idx on public.shares (verified_starter_id)
  where verified_starter_id is not null;

comment on column public.quotes.verified_starter_id is 'Server-owned: the starter quote this row''s body, author and source match exactly, else null (trigger quotes_set_verified).';
comment on column public.shares.verified_starter_id is 'Server-owned: the starter quote this share''s body, author and source match exactly, else null (trigger shares_set_verified).';

-- SECURITY INVOKER: starter_quotes is readable by every signed-in user (and
-- by the secret key), which is all the lookup needs.
create function private.set_verified_starter()
returns trigger
language plpgsql
volatile
set search_path = ''
as $$
begin
  new.verified_starter_id := (
    select s.id
    from public.starter_quotes s
    where s.body = new.body
      and s.author is not distinct from new.author
      and s.source is not distinct from new.source
    order by s.id
    limit 1
  );
  return new;
end;
$$;
revoke all on function private.set_verified_starter() from public, anon, authenticated;

create trigger quotes_set_verified
  before insert or update of body, author, source, verified_starter_id on public.quotes
  for each row execute function private.set_verified_starter();

create trigger shares_set_verified
  before insert or update of body, author, source, verified_starter_id on public.shares
  for each row execute function private.set_verified_starter();

-- Backfill. The trigger computes the value; quotes_set_updated_at is paused so
-- a backfill doesn't look like an edit.
alter table public.quotes disable trigger quotes_set_updated_at;
update public.quotes q
set verified_starter_id = null
where exists (
  select 1 from public.starter_quotes s
  where s.body = q.body and s.author is not distinct from q.author and s.source is not distinct from q.source
);
alter table public.quotes enable trigger quotes_set_updated_at;

update public.shares sh
set verified_starter_id = null
where exists (
  select 1 from public.starter_quotes s
  where s.body = sh.body and s.author is not distinct from sh.author and s.source is not distinct from sh.source
);
