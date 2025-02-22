# blog.cyril.email

Hand-written static HTML, served by GitHub Pages from `main` (see `CNAME`).
No framework, no front matter, no templating language. Posts are plain HTML
files; everything else is derived from them by one script.

## Publishing a post

1. Write `posts/<YYYY-MM-DD>/<slug>.html`, copying the `<head>` of an existing
   post and adjusting it (see the metadata contract below).
2. Run the build:

   ```sh
   ruby bin/build.rb
   ```

3. Commit the post together with the files the build regenerated.

That is the whole workflow. The index list, the JSON Feed and the sitemap are
never edited by hand.

## Commands

| Command | Effect |
| --- | --- |
| `ruby bin/build.rb` | Regenerates every derived file. |
| `ruby bin/build.rb --check` | Verifies without writing; exits non-zero if anything is stale or inconsistent. |
| `ruby test/build_test.rb` | Runs the test suite. |

Ruby 3.x, standard library only — no gems, no `Gemfile`, no bundler.
The output is deterministic: it embeds no timestamp and sorts by a total
order, so a local run and a CI run produce identical bytes.

## What the build generates

- `feed.json` — JSON Feed 1.1, summary-only, newest first.
- `sitemap.xml` — `<loc>` and `<lastmod>` only. Google states it ignores
  `<priority>` and `<changefreq>`, so they are not emitted.
- `index.html` — **two regions only**: the `<ol>` list of posts, and the
  `blogPost` array inside the JSON-LD block. Everything else in that file —
  header, navigation, headings, footer, page metadata — is hand-written and
  never touched.

Those two regions belong to the build. Editing them by hand works until the
next run overwrites the change; `--check` reports the discrepancy first. To
change what they say, change the post.

The build finds them by exact markup — the `<main>` tag, `<ol>` at eight
spaces with its items at twelve, and `"blogPost": [` with its entries at
sixteen. Reindenting the file or adding an attribute to `<main>` breaks the
anchors, though it fails loudly rather than silently.

## Metadata contract

Read from each post's `<head>`:

| Field | Role |
| --- | --- |
| `<meta property="og:title">` | required — the title in the list, the feed and the JSON-LD |
| `<meta property="article:published_time">` | required — `YYYY-MM-DD`, or a full ISO 8601 timestamp |
| `<link rel="canonical">` | required — must be exactly `https://blog.cyril.email/` + the file's path |
| `<meta name="description">` | required — the feed's `summary` and `content_text`, which JSON Feed requires |
| `<meta property="article:section">`, `<meta property="article:tag">` | the feed's `tags` |
| `<meta property="article:modified_time">` | optional — sets `<lastmod>`; add it when correcting a published post |
| `<html lang>` | must match the JSON-LD `inLanguage` |

Every page, articles and `404.html` included, also needs the feed
autodiscovery link in its `<head>`. Attribute order, quoting and a `title`
attribute are all free; only the meaning is checked:

```html
<link rel="alternate" type="application/feed+json" title="Cyril Kato's blog" href="/feed.json">
```

Each post also carries a JSON-LD `BlogPosting`. It states several of the same
facts as the `<meta>` tags, and the two had silently drifted apart, so the
build now requires eight of them to agree: `headline`, `description`,
`datePublished`, `dateModified`, `url`, `mainEntityOfPage.@id`,
`articleSection` and `inLanguage`.

Nothing else in the block is compared. `author`, `publisher`, `isPartOf`,
`about` and `citation` have no `<meta>` counterpart to compare against, and
`keywords` deliberately carries a richer list than `article:tag`.

The posts carry no `image`. The only one available was the author portrait,
at 384px and identical on every article — below the size Google asks for and
saying nothing about any particular piece. It is still the `og:image`, where a
face is the point, but it does not belong in the article's structured data.

`wordCount` used to be there and was removed: every declared value overstated
the real count by 16% to 129%, one post had none at all, and all of them were
strings where schema.org expects an integer. Nothing reads the field — Google
uses it for no rich result — so it was dropped rather than kept true. Do not
reintroduce it by copying an older post's `<head>`.

## What the build refuses

It aborts rather than publishing something quietly wrong:

- a post outside a `posts/<YYYY-MM-DD>/` directory (it would never appear);
- a `canonical` that disagrees with the file's own path;
- a publication date that disagrees with its directory name;
- a `modified_time` earlier than the publication date;
- a date that only looks like one (`2026-13-45`);
- an HTML entity it cannot resolve (`&nbsp;`, `&eacute;`) — use the character;
- a missing or empty `og:title`, `description` or `canonical`;
- a page with no `<head>`;
- a file that is not valid UTF-8;
- no posts at all, an unrecognised argument, or an `index.html` whose two
  anchors it can no longer find.

One known limit: the entity check keys on the semicolon, so `&nbsp;` is caught
but `&copy 2026` — which a browser still expands — is not. Nothing on the site
uses that form.

Two further inconsistencies fail `--check` and print a warning when writing,
since they do not corrupt the output: a page missing the autodiscovery link,
and a JSON-LD field contradicting the `<meta>` tags.

## Tests

```sh
ruby test/build_test.rb
```

Sixty checks, standard library only. Each one runs the real script against
a throwaway site built from scratch in a temporary directory, so publishing an
article can never break the suite; only the last check looks at this
repository.

The suite was measured by mutation rather than trusted: thirty-three deliberate
regressions were introduced into `bin/build.rb` one at a time, and thirty-one
turn the suite red. A harmless edit leaves it green, so it does not simply
fail at everything. The two that survive are known:

- a tie-break comparator returning `0` for posts sharing a date — the order is
  then left to `Array#sort`, which happens to preserve the glob order on the
  inputs tested. Reversing the tie-break, the realistic form of that bug, is
  caught.
- removing `verify_index`, the assertion guarding the `index.html` rewrite. It
  only fires when a substitution has already gone wrong, and every input that
  would provoke it fails earlier for another reason.

## Publishing and `_config.yml`

GitHub Pages builds this repository with Jekyll, which publishes every file it
is not told to skip — `README.md` was reachable at `blog.cyril.email/README.md`
before `_config.yml` existed. That file excludes `bin`, `test`, `README.md`,
`.github` and `_site` from the published site.

`CNAME` is on that list for a subtler reason. On GitHub Pages the effective
default exclude list is exactly `["CNAME"]` — which is why `/README.md`
answered 200 while `/CNAME` answered 404. Pages pins Jekyll 3, where `exclude`
replaces that list rather than extending it (Jekyll 4 appends), so declaring
your own list without `CNAME` starts publishing it.

`bin/build.rb` keeps its own copy of the unpublished directories, so an HTML
fixture under `test/` or a locally built `_site/` is not mistaken for a page
that owes a feed link.

After the first deploy, confirm it took effect:

```sh
curl -sI https://blog.cyril.email/bin/build.rb | head -1   # expect 404
```

## CI

`.github/workflows/build.yml` runs the tests and `--check` on pushes and pull
requests, with read-only permissions. It deliberately does **not** regenerate
and commit:

- `git diff --quiet -- feed.json` silently reports no change for a file git
  does not track yet, so such a job passes while committing nothing;
- more fundamentally, a commit pushed with the default `GITHUB_TOKEN` does not
  trigger a GitHub Pages build. The derived files would land in the repository
  but not on the site, leaving the published feed one post behind.

Generating locally and committing the result in the same commit as the post
avoids both. The job's purpose is to fail when that was forgotten.
