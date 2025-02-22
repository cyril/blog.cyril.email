#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds every derived file of blog.cyril.email from the posts themselves.
#
#   ruby bin/build.rb           # writes feed.json, sitemap.xml, index.html
#   ruby bin/build.rb --check   # exits 1 if any of them is out of date
#
# The posts are the single source of truth. Everything else — the JSON Feed,
# the sitemap, the <ol> list on the index and the JSON-LD blogPost array — is
# derived from the metadata already present in the <head> of
# posts/<date>/<slug>.html, so publishing means writing one file and running
# this script.
#
# In index.html only those two regions are rewritten; the header, navigation,
# headings, footer and page metadata are yours and are never touched.
#
# The output is deterministic — it never embeds the current time, and posts
# are ordered by a total order over [date, path] rather than by whatever order
# the filesystem hands back. A local run and a CI run on another Ruby and
# another architecture produce the same bytes.

require "cgi"
require "date"
require "json"

module Build
  ROOT      = File.expand_path("..", __dir__)
  SITE_URL  = "https://blog.cyril.email/"
  FEED_PATH = "/feed.json"
  FEED_URL  = "#{SITE_URL}feed.json"
  FEED_TYPE = "application/feed+json"
  TITLE     = "Cyril Kato's blog"
  SUBTITLE  = "Articles on abstract strategy board games, notation systems, and open-source development."
  LANGUAGE  = "en"
  ICON      = "#{SITE_URL}favicon/web-app-manifest-512x512.png"
  FAVICON   = "#{SITE_URL}favicon/favicon-96x96.png"

  AUTHOR = {
    name:   "Cyril Kato",
    uri:    "https://cyril.email/",
    avatar: "https://cyril.email/img/cyril-kato,w_384.webp"
  }.freeze

  # Posts live in date-named directories. Anything else under posts/ is a
  # mistake rather than a draft location — being loud about it beats silently
  # leaving an article out of the feed.
  POST_GLOB = "posts/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/*.html"

  # Directories that never reach the published site — kept in step with the
  # `exclude` list in _config.yml. An HTML file in one of them is not a page.
  UNPUBLISHED = %w[bin test vendor node_modules _site].freeze
  ANY_GLOB  = "posts/**/*.html"

  # A tag whose attribute values may themselves contain '>', which is legal
  # HTML5 and which a naive /<meta[^>]*>/ truncates.
  TAG_PATTERN  = /<(meta|link)\b((?:[^>"']|"[^"]*"|'[^']*')*)>/i
  ATTR_PATTERN = /([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/
  # CGI.unescapeHTML resolves these five by name, plus the numeric forms.
  # Anything else (&nbsp;, &eacute;) would reach the output as literal source.
  ENTITY_PATTERN      = /&([a-zA-Z][a-zA-Z0-9]*);/
  RESOLVABLE_ENTITIES = %w[amp lt gt quot apos].freeze

  # The two regions of index.html this script owns, matched structurally so
  # that the file needs no machine-readable markers of its own.
  LIST_REGION = %r{(<main>.*?<ol>\n            )(.*?)(\n        </ol>)}m
  LD_REGION   = %r{("blogPost": \[\n                )(.*?)(\n            \])}m

  Post = Struct.new(:title, :summary, :date, :modified, :url, :tags, :path, keyword_init: true) do
    # Posts carry a date, not a time; midnight UTC keeps it unambiguous.
    def timestamp
      "#{date}T00:00:00Z"
    end

    def href
      "/#{url.delete_prefix(SITE_URL)}"
    end

    # The long form used on the index. Ruby's strftime is not locale-aware,
    # so this reads the same on every machine.
    def long_date
      Date.parse(date).strftime("%B %-d, %Y")
    end
  end

  module_function

  def relative(path)
    path.delete_prefix("#{ROOT}/")
  end

  def read(path)
    File.read(path, encoding: "UTF-8").tap do |content|
      abort "#{relative(path)}: not valid UTF-8" unless content.valid_encoding?
    end
  rescue SystemCallError => e
    abort "#{relative(path)}: #{e.message}"
  end

  # The <head>, stripped of comments and of script/style bodies — otherwise a
  # commented-out <meta> or a tag-shaped string inside the JSON-LD block is
  # picked up as real markup, and the first match wins.
  def head_of(path)
    head = read(path)[%r{<head\b[^>]*>(.*?)</head>}mi, 1]
    abort "#{relative(path)}: no <head> found" if head.nil?

    head.gsub(/<!--.*?-->/m, " ")
        .gsub(%r{<script\b.*?</script>}mi, " ")
        .gsub(%r{<style\b.*?</style>}mi, " ")
  end

  def tags_of(head, name)
    head.scan(TAG_PATTERN)
        .select { |(tag, _)| tag.casecmp?(name) }
        .map { |(_, fragment)| parse_attributes(fragment) }
  end

  def parse_attributes(fragment)
    fragment.scan(ATTR_PATTERN).each_with_object({}) do |(key, double, single), attrs|
      attrs[key.downcase] ||= double || single
    end
  end

  # Collapses the newlines and indentation of a wrapped attribute, and
  # resolves entities — refusing the ones CGI cannot resolve.
  def text(value, path, field)
    return nil if value.nil?

    # Examine the source, not the decoded result: "R&amp;D; a memoir" decodes
    # to "R&D;", which looks like an entity and is not one.
    unknown = value.scan(ENTITY_PATTERN).flatten.reject { |name| RESOLVABLE_ENTITIES.include?(name) }.first
    abort "#{relative(path)}: #{field} contains the unsupported entity &#{unknown}; — use the character itself" if unknown

    CGI.unescapeHTML(value).gsub(/\s+/, " ").strip
  end

  def meta(head, key, name, path)
    tag = tags_of(head, "meta").find { |attrs| attrs[key] == name }
    tag && text(tag["content"], path, name)
  end

  def metas(head, key, name, path)
    tags_of(head, "meta").select { |attrs| attrs[key] == name }
                         .filter_map { |attrs| text(attrs["content"], path, name) }
  end

  # Accepts a bare date as well as the full Open Graph timestamp form, and
  # rejects shapes that look like dates but are not (2026-13-45).
  def parse_date(raw, path, field)
    Date.iso8601(raw).strftime("%Y-%m-%d")
  rescue Date::Error, TypeError
    abort "#{relative(path)}: #{field} #{raw.inspect} is not a valid ISO 8601 date"
  end

  def read_post(path)
    head  = head_of(path)
    title = meta(head, "property", "og:title", path)
    raw   = meta(head, "property", "article:published_time", path)
    url   = tags_of(head, "link").find { |attrs| attrs["rel"]&.casecmp?("canonical") }&.fetch("href", nil)&.strip

    summary = meta(head, "name", "description", path)
    missing = { "og:title" => title, "description" => summary,
                "article:published_time" => raw, "canonical" => url }
              .reject { |_, value| value && !value.empty? }
              .keys
    abort "#{relative(path)}: missing #{missing.join(', ')}" unless missing.empty?

    date     = parse_date(raw, path, "article:published_time")
    expected = "#{SITE_URL}#{relative(path)}"
    abort "#{relative(path)}: canonical is #{url.inspect}, expected #{expected.inspect}" unless url == expected

    directory = File.basename(File.dirname(path))
    abort "#{relative(path)}: published_time #{date} does not match its directory #{directory}" unless date == directory

    # Optional: set article:modified_time when correcting a published post, so
    # that <lastmod> stays truthful. Google uses that field only while it is.
    raw_modified = meta(head, "property", "article:modified_time", path)
    modified     = raw_modified ? parse_date(raw_modified, path, "article:modified_time") : date
    abort "#{relative(path)}: modified_time #{modified} precedes published_time #{date}" if modified < date

    Post.new(
      title:    title,
      summary:  summary,
      date:     date,
      modified: modified,
      url:      url,
      tags:     (metas(head, "property", "article:section", path) +
                 metas(head, "property", "article:tag", path)).uniq.reject(&:empty?),
      path:     relative(path)
    )
  end

  def post_paths
    inside  = Dir.glob(File.join(ROOT, ANY_GLOB)).sort
    matched = Dir.glob(File.join(ROOT, POST_GLOB)).sort
    strays  = (inside - matched).map { |path| relative(path) }
    abort "not in a posts/<YYYY-MM-DD>/ directory, so it would never be published: #{strays.join(', ')}" unless strays.empty?

    matched
  end

  # Newest first, ties broken by ascending path so the order is total and the
  # output byte-stable whatever order the filesystem enumerates in.
  # Item ids are the canonical URLs, and read_post pins each canonical to its
  # own file path — so uniqueness is already guaranteed here.
  def posts
    post_paths.map { |path| read_post(path) }
              .sort { |a, b| (b.date <=> a.date).nonzero? || (a.path <=> b.path) }
  end

  # Every page a visitor can land on, at any depth — an article is where
  # someone actually decides to subscribe, so the link has to be there and not
  # only on the index.
  def pages
    Dir.glob(File.join(ROOT, "**", "*.html")).sort.reject do |path|
      UNPUBLISHED.include?(relative(path).split("/").first)
    end
  end

  # Matched by meaning, not byte-for-byte: attribute order, quoting style, a
  # trailing slash, an absolute href and a missing title are all fine.
  def discovery_link?(head)
    tags_of(head, "link").any? do |attrs|
      attrs["rel"].to_s.split.any? { |rel| rel.casecmp?("alternate") } &&
        attrs["type"].to_s.strip.casecmp?(FEED_TYPE) &&
        [FEED_PATH, FEED_URL].include?(attrs["href"].to_s.strip)
    end
  end

  def pages_without_discovery
    pages.reject { |path| discovery_link?(head_of(path)) }.map { |path| relative(path) }
  end

  # Each post states the same facts twice: in the <meta> tags this script
  # reads, and in its own JSON-LD block, which nothing was checking. They had
  # already drifted apart on two posts. These are the fields that must agree.
  # `keywords` is deliberately absent — every post carries a richer list there
  # than in its article:tag metas, and that is intentional. The posts carry no
  # `image`: the only one available was the author portrait, which says nothing
  # about any particular article.
  def structured_data_problems(post)
    path   = File.join(ROOT, post.path)
    html   = read(path)
    source = html[%r{<script type="application/ld\+json">(.*?)</script>}m, 1]
    return ["#{post.path}: no JSON-LD block"] if source.nil?

    data = begin
      JSON.parse(source)
    rescue JSON::ParserError => e
      return ["#{post.path}: the JSON-LD block is not valid JSON (#{e.message})"]
    end

    head = head_of(path)
    expected = {
      "headline"       => post.title,
      "description"    => post.summary,
      "datePublished"  => post.date,
      "dateModified"   => post.modified,
      "url"            => post.url,
      "articleSection" => meta(head, "property", "article:section", path),
      "inLanguage"     => parse_attributes(html[/<html\b([^>]*)>/, 1].to_s)["lang"]
    }

    problems = expected.filter_map do |field, want|
      got = data[field]
      next if got == want

      "#{post.path}: JSON-LD #{field} says #{got.inspect}, the page says #{want.inspect}"
    end

    id = data.dig("mainEntityOfPage", "@id")
    problems << "#{post.path}: JSON-LD mainEntityOfPage says #{id.inspect}, expected #{post.url.inspect}" unless id == post.url
    problems
  end

  def xml_escape(value)
    escape_html(value).gsub('"', "&quot;")
  end

  def escape_html(value)
    value.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # --- Outputs ---------------------------------------------------------------

  def json_feed(entries)
    feed = {
      version:       "https://jsonfeed.org/version/1.1",
      title:         TITLE,
      home_page_url: SITE_URL,
      feed_url:      FEED_URL,
      description:   SUBTITLE,
      language:      LANGUAGE,
      icon:          ICON,
      favicon:       FAVICON,
      # `authors` is the 1.1 form; the singular `author` is kept alongside it
      # because 1.0-era readers only look for that one.
      author:        { name: AUTHOR[:name], url: AUTHOR[:uri], avatar: AUTHOR[:avatar] },
      authors:       [{ name: AUTHOR[:name], url: AUTHOR[:uri], avatar: AUTHOR[:avatar] }],
      items:         entries.map { |post| feed_item(post) }
    }

    "#{JSON.pretty_generate(feed)}\n"
  end

  def feed_item(post)
    {
      id:             post.url,
      url:            post.url,
      title:          post.title,
      summary:        post.summary,
      # The spec requires one of content_html / content_text in every item.
      # This is a summary-only feed, so the summary is the content.
      content_text:   post.summary,
      date_published: post.timestamp,
      tags:           post.tags,
      language:       LANGUAGE
      # Dropping empty values also keeps the bytes stable across json gem
      # versions: 2.8.0 changed how pretty_generate renders an empty array.
      # Do not remove this without re-checking cross-version output.
    }.reject { |_, value| value.respond_to?(:empty?) && value.empty? }
  end

  # <loc> and <lastmod> only: Google states plainly that it ignores <priority>
  # and <changefreq>, and a hand-kept priority ladder decays into noise.
  def sitemap(entries)
    urls = [[SITE_URL, entries.map(&:modified).max]] +
           entries.map { |post| [post.url, post.modified] }
    body = urls.map { |loc, modified|
      "  <url>\n    <loc>#{xml_escape(loc)}</loc>\n    <lastmod>#{modified}</lastmod>\n  </url>"
    }.join("\n")

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      #{body}
      </urlset>
    XML
  end

  def index_html(entries)
    html = read(File.join(ROOT, "index.html"))

    list = entries.map { |post|
      ["<li>",
       "                <a href=\"#{escape_html(post.href)}\">#{escape_html(post.title)}</a>",
       "                <time datetime=\"#{post.date}\">#{post.long_date}</time>",
       "            </li>"].join("\n")
    }.join("\n            ")

    blog_posts = entries.map { |post|
      ["{",
       "                    \"@type\": \"BlogPosting\",",
       "                    \"headline\": #{post.title.to_json},",
       "                    \"datePublished\": \"#{post.date}\",",
       "                    \"url\": \"#{post.url}\"",
       "                }"].join("\n")
    }.join(",\n                ")

    html = substitute(html, LIST_REGION, list, "the <ol> list of posts")
    html = substitute(html, LD_REGION, blog_posts, "the JSON-LD blogPost array")
    verify_index(html, entries)
    html
  end

  def substitute(html, pattern, body, label)
    abort "index.html: could not locate #{label}" unless html.match?(pattern)

    html.sub(pattern) { "#{Regexp.last_match(1)}#{body}#{Regexp.last_match(3)}" }
  end

  # Rewriting markup with a regex earns a check that the result still parses
  # and still says what it should.
  def verify_index(html, entries)
    items = html[LIST_REGION, 2].to_s.scan("<li>").size
    abort "index.html: rendered #{items} list items for #{entries.size} posts" unless items == entries.size

    source = html[%r{<script type="application/ld\+json">(.*?)</script>}m, 1]
    abort "index.html: no JSON-LD block found" if source.nil?

    data = begin
      JSON.parse(source)
    rescue JSON::ParserError => e
      abort "index.html: the JSON-LD block is no longer valid JSON (#{e.message})"
    end

    urls = data.fetch("blogPost", []).map { |entry| entry["url"] }
    abort "index.html: the JSON-LD blogPost array does not match the posts" unless urls == entries.map(&:url)
  end

  # --- Driver ----------------------------------------------------------------

  def outputs(entries)
    {
      "feed.json"   => json_feed(entries),
      "sitemap.xml" => sitemap(entries),
      "index.html"  => index_html(entries)
    }
  end

  def run(check_only: false)
    entries = posts
    abort "No posts found under #{File.join(ROOT, 'posts')}" if entries.empty?

    built     = outputs(entries)
    stale     = built.reject { |name, body| File.exist?(File.join(ROOT, name)) && read(File.join(ROOT, name)) == body }
    orphans   = pages_without_discovery
    mismatches = entries.flat_map { |post| structured_data_problems(post) }

    if check_only
      problems = []
      problems << "out of date — run: ruby bin/build.rb — #{stale.keys.join(', ')}" unless stale.empty?
      problems << "missing the autodiscovery link in <head>: #{orphans.join(', ')}" unless orphans.empty?
      problems.concat(mismatches)
      abort problems.map { |problem| "error: #{problem}" }.join("\n") unless problems.empty?

      puts "feed.json, sitemap.xml and index.html are up to date (#{entries.size} posts); " \
           "autodiscovery present on #{pages.size} pages; structured data agrees with the metadata."
      return
    end

    warn "warning: missing the autodiscovery link in <head>: #{orphans.join(', ')}" unless orphans.empty?
    mismatches.each { |problem| warn "warning: #{problem}" }
    built.each { |name, body| File.write(File.join(ROOT, name), body, encoding: "UTF-8") }
    puts "Wrote #{built.keys.join(', ')} (#{entries.size} posts, latest #{entries.first.date})."
  end
end

if $PROGRAM_NAME == __FILE__
  unknown = ARGV - ["--check"]
  abort "usage: ruby bin/build.rb [--check]" unless unknown.empty?

  Build.run(check_only: ARGV.include?("--check"))
end
