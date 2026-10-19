# Starter pack sources

The onboarding starter pack (seeded by the migration `supabase/migrations/20261019040100_starter_pack.sql` into `public.starter_quotes`) holds 60 quotes by 59 authors. Every quote was checked word for word against a full text of the named work, and this file records where each one is.

## Rules used

- **Public domain.** The author died before 1955 and the work was first published before 1929. A translation is used only when the translation itself was published before 1929, and the body uses that translation's wording.
- **Checked against the text.** Each body was matched against a full text from Project Gutenberg or Wikisource, using a script that ignores only case, straight vs. curly quotes and dash style. Wikiquote was used as a second check, never as the only source. Nothing in the pack sits in a Wikiquote "Misattributed" or "Disputed" section.
- **Trimming.** Quotes may start or stop at a clause boundary. When they do, the first letter is capitalised and the last mark may become a period; the location column notes each case. Words left out of the middle are shown as " … ". Verse keeps its line breaks as newlines.
- **Typography.** Apostrophes and dashes are typographic (’ and —). Spelling is the edition's own ("labour", "storeys", "judgment").
- **Speakers.** Lines spoken by characters are credited to the author, following the usual convention. The location column names the speaker.

## The 60 quotes

Order matches `sort_order`. Ids 1–9 are the quotes already used in the UI mockups.

| id | Quote (opening) | Author | Work / translation | Exact location | Source text checked |
|---:|---|---|---|---|---|
| 1 | Trust thyself: every heart vibrates to that iron string. | Ralph Waldo Emerson | Self-Reliance | “Self-Reliance”, Essays: First Series (1841), 3rd paragraph | <https://www.gutenberg.org/ebooks/2944> |
| 2 | Hope is the thing with feathers / That perches … | Emily Dickinson | Hope (Poems, Second Series) | Poems by Emily Dickinson, Second Series (1891), I. Life, VI “Hope”, stanza 1 (comma after “all” closed with a period) | <https://www.gutenberg.org/ebooks/2679> |
| 3 | Beware; for I am fearless, and therefore powerful. | Mary Shelley | Frankenstein | 1831 edition, Chapter 20 (the creature to Victor). The 1818 text reads “Beware, for I am fearless and therefore powerful.” (PG #84) | <https://www.gutenberg.org/ebooks/42324> |
| 4 | While we are postponing, life speeds by. | Seneca | Moral Letters to Lucilius (trans. Richard M. Gummere) | Letter I “On Saving Time”, §2 (Loeb vol. 1, 1917, pp. 3–5, via Wikisource’s proofread transcription of the scan) | <https://en.wikisource.org/wiki/Moral_letters_to_Lucilius/Letter_1> |
| 5 | There is a stubbornness about me that never can … | Jane Austen | Pride and Prejudice | Chapter 31 (Vol. II ch. 8), Elizabeth to Darcy. The mockup’s “at every attempt” corrected to the source’s “with every attempt” | <https://www.gutenberg.org/ebooks/1342> |
| 6 | Do I contradict myself? / Very well then I … | Walt Whitman | Song of Myself | Song of Myself, section 51, Leaves of Grass (1891–92 edition) | <https://www.gutenberg.org/ebooks/1322> |
| 7 | But screw your courage to the sticking-place, / And … | William Shakespeare | Macbeth | Act I, Scene 7, Lady Macbeth | <https://www.gutenberg.org/ebooks/1533> |
| 8 | I went to the woods because I wished to … | Henry David Thoreau | Walden | Chapter 2, “Where I Lived, and What I Lived For” | <https://www.gutenberg.org/ebooks/205> |
| 9 | This above all: to thine own self be true; … | William Shakespeare | Hamlet | Act I, Scene 3, Polonius to Laertes | <https://www.gutenberg.org/ebooks/1524> |
| 10 | If you shed tears when you miss the sun, … | Rabindranath Tagore | Stray Birds | Stray Birds (1916), no. 6 (Tagore’s own English) | <https://www.gutenberg.org/ebooks/6524> |
| 11 | Isn’t it nice to think that tomorrow is a … | L. M. Montgomery | Anne of Green Gables | Chapter 21, Anne to Marilla | <https://www.gutenberg.org/ebooks/45> |
| 12 | If thou art pained by any external thing, it … | Marcus Aurelius | Meditations (trans. George Long) | Book VIII, §47 | <https://www.gutenberg.org/ebooks/15877> |
| 13 | I am no bird; and no net ensnares me; … | Charlotte Brontë | Jane Eyre | Chapter 23, Jane to Rochester | <https://www.gutenberg.org/ebooks/1260> |
| 14 | The tree which fills the arms grew from the … | Lao Tzu | Tao Te Ching (trans. James Legge) | Chapter 64, §2 (Legge’s parenthesis kept) | <https://www.gutenberg.org/ebooks/216> |
| 15 | Courage is resistance to fear, mastery of fear—not absence … | Mark Twain | Pudd’nhead Wilson | Chapter 12 epigraph, “Pudd’nhead Wilson’s Calendar” | <https://www.gutenberg.org/ebooks/102> |
| 16 | My heart is like a singing bird / Whose … | Christina Rossetti | A Birthday | “A Birthday”, stanza 1, lines 1–2 and 7–8 (Goblin Market and Other Poems, 1862) | <https://www.gutenberg.org/ebooks/16950> |
| 17 | You have seen how a man was made a … | Frederick Douglass | Narrative of the Life of Frederick Douglass | Chapter X | <https://www.gutenberg.org/ebooks/23> |
| 18 | Work is love made visible. | Kahlil Gibran | The Prophet | “On Work” | <https://www.gutenberg.org/ebooks/58585> |
| 19 | Why, sometimes I’ve believed as many as six impossible … | Lewis Carroll | Through the Looking-Glass | Chapter V, the White Queen | <https://www.gutenberg.org/ebooks/12> |
| 20 | What do we live for, if it is not … | George Eliot | Middlemarch | Chapter 72, Dorothea | <https://www.gutenberg.org/ebooks/145> |
| 21 | Men are disturbed not by the things which happen, … | Epictetus | Enchiridion (trans. George Long) | Encheiridion V (semicolon at the cut closed with a period) | <https://www.gutenberg.org/ebooks/10661> |
| 22 | What a lark! What a plunge! | Virginia Woolf | Mrs Dalloway | Opening page (1925), Clarissa’s thoughts | <https://www.gutenberg.org/ebooks/71865> |
| 23 | The wise are free from perplexities; the virtuous from … | Confucius | Analects (trans. James Legge) | Book IX (Tsze Han), ch. XXVIII | <https://www.gutenberg.org/ebooks/3330> |
| 24 | To travel hopefully is a better thing than to … | Robert Louis Stevenson | El Dorado | Essay “El Dorado”, last sentence, Virginibus Puerisque (1881) | <https://www.gutenberg.org/ebooks/386> |
| 25 | How do I love thee? Let me count the … | Elizabeth Barrett Browning | Sonnets from the Portuguese | Sonnet XLIII, lines 1–4 | <https://www.gutenberg.org/ebooks/2002> |
| 26 | That which we are, we are; / One equal … | Alfred, Lord Tennyson | Ulysses | “Ulysses” (1842), last lines | <https://www.gutenberg.org/ebooks/8601> |
| 27 | That is happiness; to be dissolved into something complete … | Willa Cather | My Ántonia | Book I, Chapter II | <https://www.gutenberg.org/ebooks/242> |
| 28 | If the hills are high before / And the … | Paul Laurence Dunbar | Keep A-Pluggin’ Away | “Keep A-Pluggin’ Away”, stanza 2, lines 1–3 (The Complete Poems, 1913) | <https://www.gutenberg.org/ebooks/18338> |
| 29 | The unexamined life is not worth living. | Socrates | Plato’s Apology (trans. Benjamin Jowett) | Apology 38a, Socrates after the verdict (clause trimmed from a longer sentence) | <https://www.gutenberg.org/ebooks/1656> |
| 30 | I’m not afraid of storms, for I’m learning how … | Louisa May Alcott | Little Women | Chapter 44 (“My Lord and Lady”), Amy | <https://www.gutenberg.org/ebooks/514> |
| 31 | When we try to pick out anything by itself, … | John Muir | My First Summer in the Sierra | Chapter VI, journal entry for July 27 | <https://www.gutenberg.org/ebooks/32540> |
| 32 | Let a man overcome anger by love, let him … | The Buddha | Dhammapada (trans. F. Max Müller) | Chapter XVII (Anger), verse 223 | <https://www.gutenberg.org/ebooks/2017> |
| 33 | We are all in the gutter, but some of … | Oscar Wilde | Lady Windermere’s Fan | Act III, Lord Darlington (leading “No,” dropped) | <https://www.gutenberg.org/ebooks/790> |
| 34 | Life has loveliness to sell, / All beautiful and … | Sara Teasdale | Barter | “Barter”, stanza 1, Love Songs (1917) | <https://www.gutenberg.org/ebooks/442> |
| 35 | The greatest thing in the world is for a … | Michel de Montaigne | Of Solitude (trans. Charles Cotton) | Essays, Book I, Chapter XXXVIII “Of Solitude” (Cotton, ed. Hazlitt) | <https://www.gutenberg.org/ebooks/3600> |
| 36 | With malice toward none; with charity for all; with … | Abraham Lincoln | Second Inaugural Address | Second Inaugural Address, 4 March 1865, final paragraph (semicolon at the cut closed with a period) | <https://en.wikisource.org/wiki/Abraham_Lincoln%27s_Second_Inaugural_Address> |
| 37 | A thing of beauty is a joy for ever: … | John Keats | Endymion | Book I, lines 1–3 (semicolon at the cut closed with a period) | <https://www.gutenberg.org/ebooks/24280> |
| 38 | I do not wish them to have power over … | Mary Wollstonecraft | A Vindication of the Rights of Woman | Chapter 4 (“them” = women) | <https://www.gutenberg.org/ebooks/3420> |
| 39 | I laugh when I hear that the fish in … | Kabir | Songs of Kabir (trans. Rabindranath Tagore) | Song XLIII (I. 82), lines 1–2 (1915) | <https://www.gutenberg.org/ebooks/6519> |
| 40 | It matters not how strait the gate, / How … | William Ernest Henley | Invictus | Final stanza; untitled “IV. I.M. R. T. Hamilton Bruce” in Henley’s Poems (1898), titled “Invictus” by Quiller-Couch | <https://en.wikisource.org/wiki/Poems_(Henley)/Out_of_the_night_that_covers_me> |
| 41 | At first people refuse to believe that a strange … | Frances Hodgson Burnett | The Secret Garden | Chapter XXVII “In the Garden”, opening paragraph | <https://www.gutenberg.org/ebooks/113> |
| 42 | Love all God’s creation, the whole and every grain … | Fyodor Dostoevsky | The Brothers Karamazov (trans. Constance Garnett) | Book VI, Chapter III (g) “Of Prayer, of Love, and of Contact with other Worlds”, Father Zossima | <https://www.gutenberg.org/ebooks/28054> |
| 43 | No coward soul is mine, / No trembler in … | Emily Brontë | No Coward Soul Is Mine | Stanza 1 (first published 1850; Complete Poems, ed. Shorter, 1908, p. 81; the poem runs on to p. 82) | <https://en.wikisource.org/wiki/The_Complete_Poems_of_Emily_Bront%C3%AB/No_Coward_Soul_Is_Mine> |
| 44 | The world will never starve for want of wonders; … | G. K. Chesterton | Tremendous Trifles | Essay I, “Tremendous Trifles”, last sentence | <https://www.gutenberg.org/ebooks/8092> |
| 45 | Those who cannot feel the littleness of great things … | Okakura Kakuzō | The Book of Tea | Chapter I, “The Cup of Humanity” | <https://www.gutenberg.org/ebooks/769> |
| 46 | Let us, then, be up and doing, / With … | Henry Wadsworth Longfellow | A Psalm of Life | Final stanza, Voices of the Night (1839) | <https://en.wikisource.org/wiki/Voices_of_the_Night/A_Psalm_of_Life> |
| 47 | I have as much muscle as any man, and … | Sojourner Truth | Speech at the Women’s Rights Convention, Akron | Akron, Ohio, 29 May 1851, as reported by Marius Robinson (Anti-Slavery Bugle, 21 June 1851), not the later Gage “Ain’t I a Woman?” version | <https://en.wikisource.org/wiki/Sojourner_Truth%27s_Women%27s_Rights_Convention_Speech_(1851)> |
| 48 | To see a World in a Grain of Sand … | William Blake | Auguries of Innocence | Lines 1–4, Pickering Manuscript (c. 1803; first printed 1863). Manuscript wording, unpunctuated | <https://en.wikisource.org/wiki/The_Pickering_Manuscript/Auguries_of_Innocence> |
| 49 | There is nothing stronger than those two: patience and … | Leo Tolstoy | War and Peace (trans. Louise and Aylmer Maude) | Book Ten, Chapter XVI, Kutúzov to Prince Andrew | <https://www.gutenberg.org/ebooks/2600> |
| 50 | The world stands out on either side / No … | Edna St. Vincent Millay | Renascence | “Renascence” (1912), closing passage (Renascence and Other Poems, 1917) | <https://www.gutenberg.org/ebooks/109> |
| 51 | The great man is he who does not lose … | Mencius | Mencius (trans. James Legge) | Book IV (Li Lou), Part II, ch. 12 | <https://en.wikisource.org/wiki/The_Chinese_Classics/Volume_2/The_Works_of_Mencius/chapter08> |
| 52 | No one is useless in this world … who … | Charles Dickens | Our Mutual Friend | Book III, Chapter 9, John Rokesmith to Bella (speech tag omitted) | <https://www.gutenberg.org/ebooks/883> |
| 53 | If Winter comes, can Spring be far behind? | Percy Bysshe Shelley | Ode to the West Wind | Last line (Prometheus Unbound … with Other Poems, 1820) | <https://en.wikisource.org/wiki/Prometheus_Unbound;_a_lyrical_drama_in_four_acts_with_other_poems/Ode_to_the_West_Wind> |
| 54 | Success is to be measured not so much by … | Booker T. Washington | Up from Slavery | Chapter II, “Boyhood Days” | <https://www.gutenberg.org/ebooks/2376> |
| 55 | One ought, every day at least, to hear a … | Johann Wolfgang von Goethe | Wilhelm Meister’s Apprenticeship (trans. Thomas Carlyle) | Book V, Chapter I, Serlo | <https://www.gutenberg.org/ebooks/36483> |
| 56 | I feel in keen sympathy with my fellow-creatures, for … | Zitkala-Ša | The Great Spirit | Essay “The Great Spirit” (first published 1902 as “Why I Am a Pagan”), American Indian Stories (1921) | <https://www.gutenberg.org/ebooks/10376> |
| 57 | Ah, but a man’s reach should exceed his grasp, … | Robert Browning | Andrea del Sarto | “Andrea del Sarto”, lines 97–98, Men and Women (1855) | <https://www.gutenberg.org/ebooks/17393> |
| 58 | My heart leaps up when I behold / A … | William Wordsworth | My Heart Leaps Up | Lines 1–6, Poems in Two Volumes (1807), vol. 2 | <https://www.gutenberg.org/ebooks/8824> |
| 59 | Silence is the cornerstone of character. | Ohiyesa (Charles Eastman) | The Soul of the Indian | Chapter IV, “Barbarism and the Moral Code” | <https://www.gutenberg.org/ebooks/340> |
| 60 | No man is an island, entire of itself; every … | John Donne | Devotions upon Emergent Occasions | Meditation XVII (modernized spelling; 1624: “No man is an Iland, intire of it selfe”) | <https://en.wikisource.org/wiki/Devotions/Meditation_17> |

## Judgement calls

- **Seneca (4), Gummere translation.** Gummere's Loeb translation was published in 1917, so it meets the pre-1929 rule and is public domain in the US. Gummere died in 1969, so in countries that use life plus 70 years it stays protected until 2040. Swap in an older translation (for example Thomas Lodge, 1614) if the app ships in those markets.
- **Dickinson (2).** The mockup used the dash-and-quotation-mark text ("“Hope” is the thing with feathers –"). That text comes from Thomas Johnson's 1955 edition, which Harvard treats as copyrighted. The pack uses the 1891 first printing instead.
- **Austen (5).** The mockup had "at every attempt". The text reads "with every attempt", so the body was corrected.
- **Shelley (3).** The required wording matches the 1831 revised edition. The 1818 first edition has different punctuation: "Beware, for I am fearless and therefore powerful."
- **Sojourner Truth (47).** The words come from Marius Robinson's report of the 1851 Akron speech, printed in the *Anti-Slavery Bugle* on 21 June 1851. That is a reporter's transcription, but it is the only account written at the time. The better-known "Ain't I a Woman?" version was written by Frances Gage in 1863, twelve years later, in a Southern dialect that Truth (raised in New York, Dutch-speaking) did not use, so it is not used here. The Wikisource transcription could not be checked against the newspaper scan, because the Library of Congress site blocks automated access.
- **Traditional attributions.** The Analects (23) were compiled by Confucius's students, the Tao Te Ching (14) is traditionally credited to Lao Tzu, and the Dhammapada (32) is traditionally credited to the Buddha. The Apology line (29) is Socrates speaking in Plato's account. The pack follows the standard attributions and names the translation.
- **Mencius (51).** Wikiquote files this line under "Attributed", meaning it gives no citation there. It was checked directly in Legge's translation (Li Lou II, ch. 12), so it stays.
- **Henley (40).** Henley left the poem untitled ("IV. I.M. R. T. Hamilton Bruce"). Arthur Quiller-Couch gave it the title "Invictus" in the Oxford Book of English Verse (1900), and the source field uses that title because readers know it.
- **Blake (48).** The text is the manuscript wording, which has no punctuation. Rossetti's punctuated text of 1863 is just as valid if a punctuated version is preferred.
- **Donne (60).** Modernised spelling, as Wikisource and most editions print it. The 1624 original reads "No man is an Iland, intire of it selfe; every man is a peece of the Continent, a part of the maine".
- **Franklin, Roosevelt, Aristotle (Chase), Kipling, Shaw, Hugo (Hapgood) and Aesop (Townsend)** were also verified but cut to keep the pack at 60. Their verified lines were: Franklin, "Lost time is never found again" (*The Way to Wealth*); Roosevelt, "the man who is actually in the arena" (*Citizenship in a Republic*, 1910); Aristotle, "it is not one swallow or one fine day that makes a spring" (*Nicomachean Ethics* I.7, trans. D. P. Chase); Kipling, the opening of "If—" (*Rewards and Fairies*, 1910); Shaw, "This is the true joy in life…" (*Man and Superman*, Epistle Dedicatory); Hugo, "obscure heroes" (*Les Misérables*, trans. Hapgood); Aesop, "Slow but steady wins the race" (trans. Townsend).
- **Helen Keller** was left out even though the brief suggested her. She died in 1968, which breaks the "died before 1955" rule.

## Excluded as misattributed

These are famous quotes that were deliberately rejected.

| Quote | Usually credited to | Why rejected |
|---|---|---|
| "Be yourself; everyone else is already taken." | Oscar Wilde | Wikiquote: Misattributed. Not in any of his works. |
| "Twenty years from now you will be more disappointed by the things that you didn't do…" | Mark Twain | Wikiquote: Misattributed. |
| "The secret of getting ahead is getting started." | Mark Twain | Wikiquote: Misattributed. |
| "What lies behind us and what lies ahead of us are tiny matters compared to what lies within us." | Ralph Waldo Emerson | Wikiquote: Misattributed. |
| "Go confidently in the direction of your dreams! Live the life you've imagined." | Henry David Thoreau | A misquotation. *Walden* (Conclusion) reads "if one advances confidently in the direction of his dreams, and endeavors to live the life which he has imagined…". |
| "It is never too late to be what you might have been." | George Eliot | No match anywhere in the full text of *Middlemarch* (PG #145), even though Wikiquote currently lists it under *Middlemarch* with no citation. |
| "If you look the right way, you can see that the whole world is a garden." | Frances Hodgson Burnett | No match in the full text of *The Secret Garden* (PG #113). |
| "The way to right wrongs is to turn the light of truth upon them." | Ida B. Wells | Not found in *Southern Horrors* (1892) or *The Red Record* (1895). No pre-1929 source was found. |
| "Whatever you can do, or dream you can, begin it. Boldness has genius, power, and magic in it." | Goethe | Wikiquote: Misattributed. It comes from John Anster's loose 1835 version of *Faust*, popularised by W. H. Murray. |
| "We are what we repeatedly do. Excellence, then, is not an act, but a habit." | Aristotle | Wikiquote: Misattributed. It is Will Durant's summary of Aristotle (1926). |
| "Be kind, for everyone you meet is fighting a hard battle." | Plato | Wikiquote: Misattributed. |
| "The secret of change is to focus all of your energy, not on fighting the old, but on building the new." | Socrates | Wikiquote: Misattributed. It comes from Dan Millman's 1980 novel. |
| "Luck is what happens when preparation meets opportunity." | Seneca | Wikiquote: Disputed. |
| "In the end, it's not the years in your life that count. It's the life in your years." | Abraham Lincoln | Wikiquote: Misattributed. |
| "Tell me and I forget. Teach me and I remember. Involve me and I learn." | Benjamin Franklin | Wikiquote: Misattributed. |
| "Be the change you wish to see in the world." | Mahatma Gandhi | Wikiquote: Misattributed. It is a paraphrase. |
| "The journey of a thousand miles begins with a single step." | Confucius | Wikiquote: Misattributed. The idea is from the Tao Te Ching, ch. 64, which is in the pack in Legge's real wording (14). |
| "Give a man a fish and you feed him for a day…" | Lao Tzu | Wikiquote: Misattributed. |
| "There is no way to happiness; happiness is the way." | The Buddha | Wikiquote: Misattributed. |
| "Look to this day, for it is life…" | Kalidasa | Wikiquote: Misattributed. |
| "Humankind has not woven the web of life…" | Chief Seattle | Wikiquote: Misattributed. It was written by Ted Perry for a 1971 film script. |

These popular paraphrases were also replaced with the translation's real wording:
- "The two most powerful warriors are patience and time" (Tolstoy). The Maude text reads "there is nothing stronger than those two: patience and time" (49).
- "Very little is needed to make a happy life" (Marcus Aurelius). Long's translation (VII.67) reads "very little indeed is necessary for living a happy life", so a different, exact passage was used (12).
