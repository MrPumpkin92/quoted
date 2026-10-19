-- Migration: seed public.starter_quotes with the onboarding starter pack.
--
-- This migration is the source of truth for the starter pack. It runs on the
-- local stack (supabase db reset) and on hosted (supabase db push), so the pack
-- exists everywhere the table does. Sources, exact locations, judgement calls
-- and the misattributions that were rejected: docs/starter-pack-sources.md
--
-- Migrations run once per database. To change the pack later, add a new
-- migration rather than editing this file. If a later migration reorders rows,
-- note that starter_quotes.sort_order is a non-deferrable unique constraint, so
-- an upsert that swaps sort_order values between rows fails partway through;
-- move the rows to free values first.

-- Quoted starter pack: 60 short public-domain quotes with checked attributions.
-- Each body is the exact wording of the edition or translation named in `source`.
-- Verse line breaks are real newlines. " … " marks words left out.
-- Sources, exact locations and the excluded misattributions: docs/starter-pack-sources.md
-- Idempotent: re-running updates rows in place by id.

insert into public.starter_quotes (id, body, body_format, author, source, sort_order) values
  (1, $q$Trust thyself: every heart vibrates to that iron string.$q$, '[]'::jsonb, $q$Ralph Waldo Emerson$q$, $q$Self-Reliance$q$, 1),
  (2, $q$Hope is the thing with feathers
That perches in the soul,
And sings the tune without the words,
And never stops at all.$q$, '[]'::jsonb, $q$Emily Dickinson$q$, $q$Hope (Poems, Second Series)$q$, 2),
  (3, $q$Beware; for I am fearless, and therefore powerful.$q$, '[]'::jsonb, $q$Mary Shelley$q$, $q$Frankenstein$q$, 3),
  (4, $q$While we are postponing, life speeds by.$q$, '[]'::jsonb, $q$Seneca$q$, $q$Moral Letters to Lucilius (trans. Richard M. Gummere)$q$, 4),
  (5, $q$There is a stubbornness about me that never can bear to be frightened at the will of others. My courage always rises with every attempt to intimidate me.$q$, '[]'::jsonb, $q$Jane Austen$q$, $q$Pride and Prejudice$q$, 5),
  (6, $q$Do I contradict myself?
Very well then I contradict myself,
(I am large, I contain multitudes.)$q$, '[]'::jsonb, $q$Walt Whitman$q$, $q$Song of Myself$q$, 6),
  (7, $q$But screw your courage to the sticking-place,
And we’ll not fail.$q$, '[]'::jsonb, $q$William Shakespeare$q$, $q$Macbeth$q$, 7),
  (8, $q$I went to the woods because I wished to live deliberately, to front only the essential facts of life, and see if I could not learn what it had to teach, and not, when I came to die, discover that I had not lived.$q$, '[]'::jsonb, $q$Henry David Thoreau$q$, $q$Walden$q$, 8),
  (9, $q$This above all: to thine own self be true;
And it must follow, as the night the day,
Thou canst not then be false to any man.$q$, '[]'::jsonb, $q$William Shakespeare$q$, $q$Hamlet$q$, 9),
  (10, $q$If you shed tears when you miss the sun, you also miss the stars.$q$, '[]'::jsonb, $q$Rabindranath Tagore$q$, $q$Stray Birds$q$, 10),
  (11, $q$Isn’t it nice to think that tomorrow is a new day with no mistakes in it yet?$q$, '[]'::jsonb, $q$L. M. Montgomery$q$, $q$Anne of Green Gables$q$, 11),
  (12, $q$If thou art pained by any external thing, it is not this thing that disturbs thee, but thy own judgment about it. And it is in thy power to wipe out this judgment now.$q$, '[]'::jsonb, $q$Marcus Aurelius$q$, $q$Meditations (trans. George Long)$q$, 12),
  (13, $q$I am no bird; and no net ensnares me; I am a free human being with an independent will, which I now exert to leave you.$q$, '[]'::jsonb, $q$Charlotte Brontë$q$, $q$Jane Eyre$q$, 13),
  (14, $q$The tree which fills the arms grew from the tiniest sprout; the tower of nine storeys rose from a (small) heap of earth; the journey of a thousand li commenced with a single step.$q$, '[]'::jsonb, $q$Lao Tzu$q$, $q$Tao Te Ching (trans. James Legge)$q$, 14),
  (15, $q$Courage is resistance to fear, mastery of fear—not absence of fear.$q$, '[]'::jsonb, $q$Mark Twain$q$, $q$Pudd’nhead Wilson$q$, 15),
  (16, $q$My heart is like a singing bird
Whose nest is in a watered shoot; …
My heart is gladder than all these
Because my love is come to me.$q$, '[]'::jsonb, $q$Christina Rossetti$q$, $q$A Birthday$q$, 16),
  (17, $q$You have seen how a man was made a slave; you shall see how a slave was made a man.$q$, '[]'::jsonb, $q$Frederick Douglass$q$, $q$Narrative of the Life of Frederick Douglass$q$, 17),
  (18, $q$Work is love made visible.$q$, '[]'::jsonb, $q$Kahlil Gibran$q$, $q$The Prophet$q$, 18),
  (19, $q$Why, sometimes I’ve believed as many as six impossible things before breakfast.$q$, '[]'::jsonb, $q$Lewis Carroll$q$, $q$Through the Looking-Glass$q$, 19),
  (20, $q$What do we live for, if it is not to make life less difficult to each other?$q$, '[]'::jsonb, $q$George Eliot$q$, $q$Middlemarch$q$, 20),
  (21, $q$Men are disturbed not by the things which happen, but by the opinions about the things.$q$, '[]'::jsonb, $q$Epictetus$q$, $q$Enchiridion (trans. George Long)$q$, 21),
  (22, $q$What a lark! What a plunge!$q$, '[]'::jsonb, $q$Virginia Woolf$q$, $q$Mrs Dalloway$q$, 22),
  (23, $q$The wise are free from perplexities; the virtuous from anxiety; and the bold from fear.$q$, '[]'::jsonb, $q$Confucius$q$, $q$Analects (trans. James Legge)$q$, 23),
  (24, $q$To travel hopefully is a better thing than to arrive, and the true success is to labour.$q$, '[]'::jsonb, $q$Robert Louis Stevenson$q$, $q$El Dorado$q$, 24),
  (25, $q$How do I love thee? Let me count the ways.
I love thee to the depth and breadth and height
My soul can reach, when feeling out of sight
For the ends of Being and ideal Grace.$q$, '[]'::jsonb, $q$Elizabeth Barrett Browning$q$, $q$Sonnets from the Portuguese$q$, 25),
  (26, $q$That which we are, we are;
One equal temper of heroic hearts,
Made weak by time and fate, but strong in will
To strive, to seek, to find, and not to yield.$q$, '[]'::jsonb, $q$Alfred, Lord Tennyson$q$, $q$Ulysses$q$, 26),
  (27, $q$That is happiness; to be dissolved into something complete and great.$q$, '[]'::jsonb, $q$Willa Cather$q$, $q$My Ántonia$q$, 27),
  (28, $q$If the hills are high before
And the paths are hard to climb,
Keep a-pluggin’ away.$q$, '[]'::jsonb, $q$Paul Laurence Dunbar$q$, $q$Keep A-Pluggin’ Away$q$, 28),
  (29, $q$The unexamined life is not worth living.$q$, '[]'::jsonb, $q$Socrates$q$, $q$Plato’s Apology (trans. Benjamin Jowett)$q$, 29),
  (30, $q$I’m not afraid of storms, for I’m learning how to sail my ship.$q$, '[]'::jsonb, $q$Louisa May Alcott$q$, $q$Little Women$q$, 30),
  (31, $q$When we try to pick out anything by itself, we find it hitched to everything else in the universe.$q$, '[]'::jsonb, $q$John Muir$q$, $q$My First Summer in the Sierra$q$, 31),
  (32, $q$Let a man overcome anger by love, let him overcome evil by good; let him overcome the greedy by liberality, the liar by truth!$q$, '[]'::jsonb, $q$The Buddha$q$, $q$Dhammapada (trans. F. Max Müller)$q$, 32),
  (33, $q$We are all in the gutter, but some of us are looking at the stars.$q$, '[]'::jsonb, $q$Oscar Wilde$q$, $q$Lady Windermere’s Fan$q$, 33),
  (34, $q$Life has loveliness to sell,
All beautiful and splendid things,
Blue waves whitened on a cliff,
Soaring fire that sways and sings,
And children’s faces looking up
Holding wonder like a cup.$q$, '[]'::jsonb, $q$Sara Teasdale$q$, $q$Barter$q$, 34),
  (35, $q$The greatest thing in the world is for a man to know that he is his own.$q$, '[]'::jsonb, $q$Michel de Montaigne$q$, $q$Of Solitude (trans. Charles Cotton)$q$, 35),
  (36, $q$With malice toward none; with charity for all; with firmness in the right, as God gives us to see the right, let us strive on to finish the work we are in.$q$, '[]'::jsonb, $q$Abraham Lincoln$q$, $q$Second Inaugural Address$q$, 36),
  (37, $q$A thing of beauty is a joy for ever:
Its loveliness increases; it will never
Pass into nothingness.$q$, '[]'::jsonb, $q$John Keats$q$, $q$Endymion$q$, 37),
  (38, $q$I do not wish them to have power over men; but over themselves.$q$, '[]'::jsonb, $q$Mary Wollstonecraft$q$, $q$A Vindication of the Rights of Woman$q$, 38),
  (39, $q$I laugh when I hear that the fish in the water is thirsty:
You do not see that the Real is in your home, and you wander from forest to forest listlessly!$q$, '[]'::jsonb, $q$Kabir$q$, $q$Songs of Kabir (trans. Rabindranath Tagore)$q$, 39),
  (40, $q$It matters not how strait the gate,
How charged with punishments the scroll,
I am the master of my fate:
I am the captain of my soul.$q$, '[]'::jsonb, $q$William Ernest Henley$q$, $q$Invictus$q$, 40),
  (41, $q$At first people refuse to believe that a strange new thing can be done, then they begin to hope it can be done, then they see it can be done—then it is done and all the world wonders why it was not done centuries ago.$q$, '[]'::jsonb, $q$Frances Hodgson Burnett$q$, $q$The Secret Garden$q$, 41),
  (42, $q$Love all God’s creation, the whole and every grain of sand in it. Love every leaf, every ray of God’s light. Love the animals, love the plants, love everything.$q$, '[]'::jsonb, $q$Fyodor Dostoevsky$q$, $q$The Brothers Karamazov (trans. Constance Garnett)$q$, 42),
  (43, $q$No coward soul is mine,
No trembler in the world’s storm-troubled sphere:
I see Heaven’s glories shine,
And faith shines equal, arming me from fear.$q$, '[]'::jsonb, $q$Emily Brontë$q$, $q$No Coward Soul Is Mine$q$, 43),
  (44, $q$The world will never starve for want of wonders; but only for want of wonder.$q$, '[]'::jsonb, $q$G. K. Chesterton$q$, $q$Tremendous Trifles$q$, 44),
  (45, $q$Those who cannot feel the littleness of great things in themselves are apt to overlook the greatness of little things in others.$q$, '[]'::jsonb, $q$Okakura Kakuzō$q$, $q$The Book of Tea$q$, 45),
  (46, $q$Let us, then, be up and doing,
With a heart for any fate;
Still achieving, still pursuing,
Learn to labor and to wait.$q$, '[]'::jsonb, $q$Henry Wadsworth Longfellow$q$, $q$A Psalm of Life$q$, 46),
  (47, $q$I have as much muscle as any man, and can do as much work as any man.$q$, '[]'::jsonb, $q$Sojourner Truth$q$, $q$Speech at the Women’s Rights Convention, Akron$q$, 47),
  (48, $q$To see a World in a Grain of Sand
And a Heaven in a Wild Flower
Hold Infinity in the palm of your hand
And Eternity in an hour$q$, '[]'::jsonb, $q$William Blake$q$, $q$Auguries of Innocence$q$, 48),
  (49, $q$There is nothing stronger than those two: patience and time, they will do it all.$q$, '[]'::jsonb, $q$Leo Tolstoy$q$, $q$War and Peace (trans. Louise and Aylmer Maude)$q$, 49),
  (50, $q$The world stands out on either side
No wider than the heart is wide;
Above the world is stretched the sky,—
No higher than the soul is high.$q$, '[]'::jsonb, $q$Edna St. Vincent Millay$q$, $q$Renascence$q$, 50),
  (51, $q$The great man is he who does not lose his child’s-heart.$q$, '[]'::jsonb, $q$Mencius$q$, $q$Mencius (trans. James Legge)$q$, 51),
  (52, $q$No one is useless in this world … who lightens the burden of it for any one else.$q$, '[]'::jsonb, $q$Charles Dickens$q$, $q$Our Mutual Friend$q$, 52),
  (53, $q$If Winter comes, can Spring be far behind?$q$, '[]'::jsonb, $q$Percy Bysshe Shelley$q$, $q$Ode to the West Wind$q$, 53),
  (54, $q$Success is to be measured not so much by the position that one has reached in life as by the obstacles which he has overcome while trying to succeed.$q$, '[]'::jsonb, $q$Booker T. Washington$q$, $q$Up from Slavery$q$, 54),
  (55, $q$One ought, every day at least, to hear a little song, read a good poem, see a fine picture, and, if it were possible, to speak a few reasonable words.$q$, '[]'::jsonb, $q$Johann Wolfgang von Goethe$q$, $q$Wilhelm Meister’s Apprenticeship (trans. Thomas Carlyle)$q$, 55),
  (56, $q$I feel in keen sympathy with my fellow-creatures, for I seem to see clearly again that all are akin.$q$, '[]'::jsonb, $q$Zitkala-Ša$q$, $q$The Great Spirit$q$, 56),
  (57, $q$Ah, but a man’s reach should exceed his grasp,
Or what’s a heaven for?$q$, '[]'::jsonb, $q$Robert Browning$q$, $q$Andrea del Sarto$q$, 57),
  (58, $q$My heart leaps up when I behold
A Rainbow in the sky:
So was it when my life began;
So is it now I am a Man;
So be it when I shall grow old,
Or let me die!$q$, '[]'::jsonb, $q$William Wordsworth$q$, $q$My Heart Leaps Up$q$, 58),
  (59, $q$Silence is the cornerstone of character.$q$, '[]'::jsonb, $q$Ohiyesa (Charles Eastman)$q$, $q$The Soul of the Indian$q$, 59),
  (60, $q$No man is an island, entire of itself; every man is a piece of the continent, a part of the main.$q$, '[]'::jsonb, $q$John Donne$q$, $q$Devotions upon Emergent Occasions$q$, 60)
on conflict (id) do update set
  body = excluded.body,
  body_format = excluded.body_format,
  author = excluded.author,
  source = excluded.source,
  sort_order = excluded.sort_order;
