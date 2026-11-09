#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/build.rb. Standard library only:
#
#   ruby test/build_test.rb
#
# Every test runs the real script against a throwaway site built from scratch
# in a temporary directory, so the suite never depends on the blog's actual
# posts — publishing an article cannot break it. Only the last group looks at
# the repository itself.

require "fileutils"
require "json"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("../bin/build.rb", __dir__)
REPO   = File.expand_path("..", __dir__)
SITE   = "https://blog.cyril.email/"
FEED_LINK = '<link rel="alternate" type="application/feed+json" title="Test blog" href="/feed.json">'

$failures = []
$total = 0

def check(label)
  $total += 1
  outcome = yield
  if outcome == true
    puts "  ok   #{label}"
  else
    puts "  FAIL #{label}#{outcome.is_a?(String) ? " — #{outcome}" : ''}"
    $failures << label
  end
rescue StandardError => e
  puts "  FAIL #{label} — #{e.class}: #{e.message}"
  $failures << label
end

def group(name)
  puts "\n#{name}"
  yield
end

# A disposable site: the script, an index with the two regions it rewrites, and
# whatever posts the test adds.
class Site
  attr_reader :dir

  def initialize(dir)
    @dir = dir
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.cp(SCRIPT, File.join(dir, "bin", "build.rb"))
    write("index.html", Site.index_html)
  end

  def path(name)  = File.join(@dir, name)
  def read(name)  = File.read(path(name), encoding: "UTF-8")
  def exist?(name) = File.exist?(path(name))

  def write(name, content)
    FileUtils.mkdir_p(File.dirname(path(name)))
    File.write(path(name), content, encoding: "UTF-8")
  end

  def patch(name, from, to)
    body = read(name)
    raise "#{name}: #{from.inspect} not found" unless body.include?(from)

    write(name, body.sub(from, to))
  end

  # Returns [combined output, success?]
  def run(*args, env: {})
    output, status = Open3.capture2e(env, "ruby", "bin/build.rb", *args, chdir: @dir)
    [output, status.success?]
  end

  def feed = JSON.parse(read("feed.json"))

  def json_ld(name)
    JSON.parse(read(name)[%r{<script type="application/ld\+json">(.*?)</script>}m, 1])
  end

  def add_post(date:, slug:, title: "A Title", description: "A description of the post.",
               modified: nil, section: "Testing", tags: %w[alpha beta], extra_head: "")
    url = "#{SITE}posts/#{date}/#{slug}.html"
    modified_meta = modified ? %(\n    <meta property="article:modified_time" content="#{modified}">) : ""
    tag_metas = tags.map { |tag| %(\n    <meta property="article:tag" content="#{tag}">) }.join
    section_meta = section.empty? ? "" : %(\n    <meta property="article:section" content="#{section}">)
    ld = {
      "@context" => "https://schema.org", "@type" => "BlogPosting",
      "headline" => title, "description" => description,
      "image" => "#{SITE}img.png",
      "datePublished" => date, "dateModified" => modified || date,
      "url" => url, "mainEntityOfPage" => { "@type" => "WebPage", "@id" => url },
      "articleSection" => section, "inLanguage" => "en"
    }

    write("posts/#{date}/#{slug}.html", <<~HTML)
      <!doctype html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <meta property="og:title" content="#{title}">
          <meta name="description" content="#{description}">
          <meta property="og:image" content="#{SITE}img.png">
          <meta property="article:published_time" content="#{date}">#{modified_meta}
#{section_meta}#{tag_metas}
          <title>#{title}</title>
          <link rel="canonical" href="#{url}">
          #{FEED_LINK}#{extra_head}
          <script type="application/ld+json">
      #{JSON.pretty_generate(ld).gsub(/^/, "        ")}
          </script>
      </head>
      <body>
          <main><article><h1>#{title}</h1></article></main>
      </body>
      </html>
    HTML
    url
  end

  # The index must carry the anchors the script substitutes between; the seed
  # row is replaced on the first build.
  def self.index_html
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <title>Test blog</title>
          #{FEED_LINK}
          <script type="application/ld+json">
              {
                  "@context": "https://schema.org",
                  "@type": "Blog",
                  "blogPost": [
                      {
                          "@type": "BlogPosting",
                          "headline": "seed",
                          "datePublished": "1970-01-01",
                          "url": "#{SITE}seed.html"
                      }
                  ]
              }
          </script>
      </head>
      <body>
          <main>
              <h2>Posts</h2>

              <ol>
                  <li>
                      <a href="/seed.html">seed</a>
                      <time datetime="1970-01-01">January 1, 1970</time>
                  </li>
              </ol>
          </main>
      </body>
      </html>
    HTML
  end
end

def sandbox
  Dir.mktmpdir("blog-build-test") do |dir|
    site = Site.new(dir)
    yield site
  end
end

# A sandbox with one ordinary post, already built.
def built_sandbox(&block)
  sandbox do |site|
    site.add_post(date: "2026-08-29", slug: "eight-pawns", title: "Eight Pawns")
    site.run
    block.call(site)
  end
end

group("Parsing the <head>") do
  check("a literal '>' in a description survives") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", description: "Why a > b matters.")
      site.run
      site.feed["items"].first["summary"] == "Why a > b matters." || site.feed["items"].first.inspect
    end
  end

  check("a literal '>' in a title survives") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", title: "King > Jeweled King")
      site.run
      site.feed["items"].first["title"] == "King > Jeweled King"
    end
  end

  check("a commented-out <meta> is ignored") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", title: "Real")
      site.patch("posts/2026-01-01/a.html", '<meta property="og:title"',
                 %(<!-- <meta property="og:title" content="Stale"> -->\n    <meta property="og:title"))
      site.run
      site.feed["items"].first["title"] == "Real"
    end
  end

  check("a tag-shaped string inside <script> is ignored") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", title: "Real")
      # Before the real tag, so that "first match wins" would pick the decoy.
      site.patch("posts/2026-01-01/a.html", '<meta property="og:title"',
                 %(<script>var s = '<meta property="og:title" content="Hijacked">';</script>\n    <meta property="og:title"))
      site.run
      site.feed["items"].first["title"] == "Real"
    end
  end

  check("a <meta> split across lines is parsed") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", title: "Wrapped")
      site.patch("posts/2026-01-01/a.html", '<meta property="og:title" content="Wrapped">',
                 %(<meta\n        property="og:title"\n        content="Wrapped">))
      site.run
      site.feed["items"].first["title"] == "Wrapped"
    end
  end

  check("an entity CGI cannot resolve is refused") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", description: "Un&nbsp;espace.")
      output, ok = site.run
      !ok && output.include?("unsupported entity &nbsp;")
    end
  end

  check("a file that is not valid UTF-8 is refused") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      File.binwrite(site.path("posts/2026-01-01/a.html"), "\xff\xfe", mode: "ab")
      output, ok = site.run
      !ok && output.include?("not valid UTF-8")
    end
  end
end

group("Invariants the build refuses to break") do
  check("a canonical that disagrees with the file path") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.patch("posts/2026-01-01/a.html", "posts/2026-01-01/a.html\">", "posts/2026-01-01/elsewhere.html\">")
      output, ok = site.run
      !ok && output.include?("expected")
    end
  end

  check("a publication date that disagrees with its directory") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.patch("posts/2026-01-01/a.html", 'article:published_time" content="2026-01-01"',
                 'article:published_time" content="2026-02-02"')
      output, ok = site.run
      !ok && output.include?("does not match its directory")
    end
  end

  check("a date that only looks like one") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.patch("posts/2026-01-01/a.html", 'article:published_time" content="2026-01-01"',
                 'article:published_time" content="2026-13-45"')
      output, ok = site.run
      !ok && output.include?("not a valid ISO 8601 date")
    end
  end

  check("a full ISO 8601 timestamp is accepted") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.patch("posts/2026-01-01/a.html", 'article:published_time" content="2026-01-01"',
                 'article:published_time" content="2026-01-01T09:30:00+01:00"')
      site.run
      site.feed["items"].first["date_published"] == "2026-01-01T00:00:00Z"
    end
  end

  check("a modification date earlier than publication") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", modified: "2020-01-01")
      output, ok = site.run
      !ok && output.include?("precedes published_time")
    end
  end

  check("a post outside a dated directory is named, not silently dropped") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.write("posts/drafts/wip.html", "<html><head></head><body></body></html>")
      output, ok = site.run
      !ok && output.include?("would never be published: posts/drafts/wip.html")
    end
  end

  check("no posts at all") do
    sandbox do |site|
      output, ok = site.run
      !ok && output.include?("No posts found")
    end
  end

  check("an unknown argument prints usage instead of generating") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      output, ok = site.run("--chek")
      !ok && output.include?("usage: ruby bin/build.rb") && !site.exist?("feed.json")
    end
  end
end

group("Feed autodiscovery") do
  variants = {
    "attributes reordered"  => '<link type="application/feed+json" rel="alternate" href="/feed.json">',
    "single quotes"         => "<link rel='alternate' type='application/feed+json' href='/feed.json'>",
    "extra whitespace"      => '<link   rel="alternate"    type="application/feed+json"   href="/feed.json">',
    "self-closing"          => '<link rel="alternate" type="application/feed+json" href="/feed.json" />',
    "absolute href"         => %(<link rel="alternate" type="application/feed+json" href="#{SITE}feed.json">),
    "no title attribute"    => '<link rel="alternate" type="application/feed+json" href="/feed.json">',
    "split across lines"    => %(<link rel="alternate"\n        type="application/feed+json"\n        href="/feed.json">)
  }

  variants.each do |label, tag|
    check("accepted: #{label}") do
      built_sandbox do |site|
        site.patch("index.html", FEED_LINK, tag)
        output, ok = site.run("--check")
        ok || output
      end
    end
  end

  check("a page that lost the link is named") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", FEED_LINK, "")
      output, ok = site.run("--check")
      !ok && output.include?("missing the autodiscovery link in <head>: posts/2026-08-29/eight-pawns.html")
    end
  end

  check("a new page at the root is guarded too") do
    built_sandbox do |site|
      site.write("about.html", "<html lang=\"en\"><head><title>About</title></head><body></body></html>")
      output, ok = site.run("--check")
      !ok && output.include?("missing the autodiscovery link in <head>: about.html")
    end
  end
end

group("Structured data agrees with the metadata") do
  check("a drifting headline is caught") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", '"headline": "Eight Pawns"', '"headline": "Something Else"')
      output, ok = site.run("--check")
      !ok && output.include?("JSON-LD headline says")
    end
  end

  check("a dateModified with no article:modified_time is caught") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", '"dateModified": "2026-08-29"', '"dateModified": "2026-09-30"')
      output, ok = site.run("--check")
      !ok && output.include?("JSON-LD dateModified says")
    end
  end

  check("a JSON-LD image is neither required nor compared") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", %("image": "#{SITE}img.png",), "")
      output, ok = site.run("--check")
      ok || output
    end
  end

  check("writing warns about drift without refusing to build") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", '"headline": "Eight Pawns"', '"headline": "Something Else"')
      output, ok = site.run
      ok && output.include?("warning:") && output.include?("Wrote feed.json")
    end
  end
end

group("Generated output") do
  check("the feed is JSON Feed 1.1 with a body in every item") do
    built_sandbox do |site|
      feed = site.feed
      feed["version"] == "https://jsonfeed.org/version/1.1" &&
        feed["items"].all? { |item| !item["content_text"].to_s.empty? } &&
        feed["author"].is_a?(Hash) && feed["authors"].is_a?(Array)
    end
  end

  check("the sitemap carries lastmod and neither priority nor changefreq") do
    built_sandbox do |site|
      xml = site.read("sitemap.xml")
      xml.include?("<lastmod>2026-08-29</lastmod>") && !xml.match?(/priority|changefreq/)
    end
  end

  check("article:modified_time drives lastmod") do
    sandbox do |site|
      site.add_post(date: "2025-01-01", slug: "a", modified: "2026-05-04")
      site.run
      site.read("sitemap.xml").include?("<lastmod>2026-05-04</lastmod>")
    end
  end

  check("the index list and the JSON-LD array follow the posts") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "old", title: "Older")
      site.add_post(date: "2026-02-02", slug: "new", title: "Newer")
      site.run
      html = site.read("index.html")
      html.include?('<a href="/posts/2026-02-02/new.html">Newer</a>') &&
        html.include?('<time datetime="2026-02-02">February 2, 2026</time>') &&
        site.json_ld("index.html")["blogPost"].map { |e| e["headline"] } == ["Newer", "Older"] &&
        !html.include?("seed")
    end
  end

  check("each index item carries the post's description, escaped") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", description: "Rooks & chariots.")
      site.run
      site.read("index.html").include?("<time datetime=\"2026-01-01\">January 1, 2026</time>\n                <p>Rooks &amp; chariots.</p>\n            </li>") &&
        site.feed["items"].first["summary"] == "Rooks & chariots."
    end
  end

  check("an ampersand is escaped in HTML and left raw in JSON") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", title: "Rooks & Chariots")
      site.run
      site.read("index.html").include?("<a href=\"/posts/2026-01-01/a.html\">Rooks &amp; Chariots</a>") &&
        site.json_ld("index.html")["blogPost"].first["headline"] == "Rooks & Chariots" &&
        site.feed["items"].first["title"] == "Rooks & Chariots"
    end
  end

  check("posts sharing a date are ordered by ascending path") do
    sandbox do |site|
      slugs = %w[m d k b p f a n c h j e g l i]
      slugs.each { |slug| site.add_post(date: "2026-03-03", slug: slug, title: slug.upcase) }
      site.run
      got = site.feed["items"].map { |item| File.basename(item["url"], ".html") }
      got == slugs.sort || "got #{got.inspect}"
    end
  end

  check("the JSON-LD block survives regeneration as valid JSON") do
    built_sandbox do |site|
      entry = site.json_ld("index.html")["blogPost"]
      # The seed row must be gone, not merely still parseable.
      entry.size == 1 && entry.first["headline"] == "Eight Pawns" &&
        !site.read("index.html").include?("seed")
    end
  end
end

group("Determinism") do
  check("index.html is a fixed point across repeated runs") do
    built_sandbox do |site|
      before = %w[index.html sitemap.xml feed.json].map { |f| site.read(f) }
      5.times { site.run }
      after = %w[index.html sitemap.xml feed.json].map { |f| site.read(f) }
      before == after
    end
  end

  check("the long date does not follow the locale") do
    built_sandbox do |site|
      site.run(env: { "LC_ALL" => "fr_FR.UTF-8", "LANG" => "fr_FR.UTF-8" })
      site.read("index.html").include?("August 29, 2026")
    end
  end

  check("--check passes on freshly generated output") do
    built_sandbox do |site|
      output, ok = site.run("--check")
      ok || output
    end
  end

  check("--check notices a one-byte drift") do
    built_sandbox do |site|
      site.write("feed.json", "#{site.read('feed.json')}\n")
      output, ok = site.run("--check")
      !ok && output.include?("out of date")
    end
  end
end

group("Regressions the earlier suite let through") do
  check("a post with an empty description is refused, not shipped without a body") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", description: "")
      output, ok = site.run
      !ok && output.include?("missing description")
    end
  end

  check("a post with no description meta at all is refused") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.patch("posts/2026-01-01/a.html", %(<meta name="description" content="A description of the post.">), "")
      output, ok = site.run
      !ok && output.include?("missing description")
    end
  end

  check("text that merely looks like an entity is not refused") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", description: "On R&amp;D; a memoir.")
      site.patch("posts/2026-01-01/a.html", %("description": "On R&amp;D; a memoir."), %("description": "On R&D; a memoir."))
      site.run
      site.feed["items"].first["summary"] == "On R&D; a memoir."
    end
  end

  check("a multi-token rel is accepted") do
    built_sandbox do |site|
      site.patch("index.html", 'rel="alternate"', 'rel="alternate feed"')
      output, ok = site.run("--check")
      ok || output
    end
  end

  check("a date Ruby could parse loosely but that is not ISO 8601 is refused") do
    sandbox do |site|
      site.add_post(date: "2026-08-29", slug: "a")
      site.patch("posts/2026-08-29/a.html", 'article:published_time" content="2026-08-29"',
                 'article:published_time" content="August 29, 2026"')
      output, ok = site.run
      !ok && output.include?("not a valid ISO 8601 date")
    end
  end

  check("a description wrapped across lines is collapsed to one line") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", description: "One two three.")
      site.patch("posts/2026-01-01/a.html", %(content="One two three.">\n),
                 %(content="One\n        two\n        three.">\n))
      site.run
      site.feed["items"].first["summary"] == "One two three."
    end
  end

  check("a tag repeating the section is not duplicated") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", section: "Testing", tags: %w[Testing alpha])
      site.run
      site.feed["items"].first["tags"] == %w[Testing alpha]
    end
  end

  check("a post with no section and no tags omits the key rather than emitting []") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", section: "", tags: [])
      site.run
      item = site.feed["items"].first
      !item.key?("tags") || "tags is #{item['tags'].inspect}"
    end
  end

  check("a title containing both & and < is escaped in the right order") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a", title: "A & B < C")
      site.run
      site.read("index.html").include?(">A &amp; B &lt; C</a>") &&
        site.json_ld("index.html")["blogPost"].first["headline"] == "A & B < C"
    end
  end

  check("an ampersand in a URL is escaped in the sitemap and the index") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "r&d")
      site.run
      site.read("sitemap.xml").include?("<loc>#{SITE}posts/2026-01-01/r&amp;d.html</loc>") &&
        site.read("index.html").include?('href="/posts/2026-01-01/r&amp;d.html"')
    end
  end

  check("a post with no <head> is named, not crashed on") do
    sandbox do |site|
      site.add_post(date: "2026-01-01", slug: "a")
      site.write("posts/2026-01-02/b.html", "<!doctype html><html lang=\"en\"><body>no head</body></html>")
      output, ok = site.run
      !ok && output.include?("no <head> found")
    end
  end

  check("a nested page is guarded like a top-level one") do
    built_sandbox do |site|
      site.write("about/index.html", "<html lang=\"en\"><head><title>About</title></head><body></body></html>")
      output, ok = site.run("--check")
      !ok && output.include?("missing the autodiscovery link in <head>: about/index.html")
    end
  end

  %w[mainEntityOfPage inLanguage articleSection description].each do |field|
    check("a drifting JSON-LD #{field} is caught") do
      built_sandbox do |site|
        case field
        when "mainEntityOfPage"
          site.patch("posts/2026-08-29/eight-pawns.html",
                     %("@id": "#{SITE}posts/2026-08-29/eight-pawns.html"), %("@id": "#{SITE}elsewhere.html"))
        when "inLanguage"    then site.patch("posts/2026-08-29/eight-pawns.html", '"inLanguage": "en"', '"inLanguage": "fr"')
        when "articleSection" then site.patch("posts/2026-08-29/eight-pawns.html", '"articleSection": "Testing"', '"articleSection": "Other"')
        when "description"   then site.patch("posts/2026-08-29/eight-pawns.html", '"description": "A description of the post."', '"description": "Something else."')
        end
        output, ok = site.run("--check")
        !ok && output.include?(field)
      end
    end
  end
end

group("Fixes the earlier measurement could not see") do
  check("a single-quoted html lang is read, not reported as drift") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", %(<html lang="en">), %(<html lang='en'>))
      output, ok = site.run("--check")
      ok || output
    end
  end

  check("a neighbouring xml:lang does not shadow lang") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", %(<html lang="en">), %(<html lang="en" xml:lang="fr">))
      output, ok = site.run("--check")
      ok || output
    end
  end

  check("an html element with no lang is reported, not silently accepted") do
    built_sandbox do |site|
      site.patch("posts/2026-08-29/eight-pawns.html", %(<html lang="en">), "<html>")
      output, ok = site.run("--check")
      !ok && output.include?("inLanguage")
    end
  end

  check("an HTML file in an unpublished directory is not treated as a page") do
    built_sandbox do |site|
      site.write("test/fixtures/case.html", "<html><head><title>fixture</title></head><body></body></html>")
      site.write("_site/index.html", "<html><head><title>built</title></head><body></body></html>")
      output, ok = site.run("--check")
      ok || output
    end
  end
end

group("The repository itself") do
  check("bin/build.rb --check passes on the real site") do
    output, status = Open3.capture2e("ruby", "bin/build.rb", "--check", chdir: REPO)
    status.success? || output
  end
end

puts
if $failures.empty?
  puts "#{$total} checks, all passing."
else
  puts "#{$total} checks, #{$failures.size} failing:"
  $failures.each { |label| puts "  - #{label}" }
  exit 1
end
